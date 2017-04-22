###

Exporting from our in-memory sync-friendly format to ipynb

###

immutable = require('immutable')

misc = require('smc-util/misc')
{required, defaults} = misc

exports.export_to_ipynb = (opts) ->
    opts = defaults opts,
        cell_list   : required
        cells       : required
        kernelspec  : {}    # official jupyter will give an error on load without properly giving this (and ask to select a kernel)
        blob_store  : undefined
        more_output : undefined  # optional map id --> list of additional output messages to replace last output message.

    ipynb =
        cells          : (cell_to_ipynb(id, opts) for id in opts.cell_list.toJS())
        metadata       :
            kernelspec: opts.kernelspec
        nbformat       : 4
        nbformat_minor : 0
    return ipynb

# Return ipynb version of the given cell as Python object
cell_to_ipynb = (id, opts) ->
    cell = opts.cells.get(id)
    metadata = {}
    obj =
        cell_type : cell.get('cell_type') ? 'code'
        source    : diff_friendly(cell.get('input'))
        metadata  : metadata

    # consistenty with jupyter -- they explicitly give collapsed true or false state no matter what
    metadata.collapsed = !!cell.get('collapsed')

    # Jupyter only gives scrolled state when true.
    if cell.get('scrolled')
        metadata.scrolled = true

    exec_count = cell.get('exec_count') ? 0
    if obj.cell_type == 'code'
        obj.execution_count = exec_count

    output = cell.get('output')
    if output?.size > 0
        obj.outputs = ipynb_outputs(output, exec_count, opts.more_output?[id], opts.blob_store)
    else if not obj.outputs? and obj.cell_type == 'code'
        obj.outputs = [] # annoying requirement of ipynb file format.
    for n, x of obj.outputs
        if x.cocalc?
            # alternative version of cell that official Jupyter doesn't support can only
            # stored in the **cell-level** metadata, not output.
            metadata.cocalc ?= {outputs:{}}
            metadata.cocalc.outputs[n] = x.cocalc
            delete x.cocalc
    return obj

ipynb_outputs = (output, exec_count, more_output, blob_store) ->
    # If the last message has the more_output field, then there may be
    # more output messages stored, which are not in the cells object.
    if output?.get("#{output.size-1}")?.get('more_output')?
        n = output.size - 1
        cnt = more_output?.length ? 0
        if cnt == 0
            # For some reason more output is not available for this cell.  So we replace
            # the more_output message by an error explaining what happened.
            output = output.set("#{n}", immutable.fromJS({"text":"WARNING: Some output was deleted.\n", "name":"stderr"}))
        else
            # Indeed, the last message has the more_output field.
            # Before converting to ipynb, we remove that last message...
            output = output.delete("#{n}")
            # Then we put in the known more output.
            for mesg in more_output
                output = output.set("#{n}", immutable.fromJS(mesg))
                n += 1
        # Now, everything continues as normal.

    outputs = []
    if output?.size > 0
        for n in [0...output.size]
            output_n = output.get("#{n}")?.toJS()
            if output_n?
                process_output_n(output_n, exec_count, blob_store)
                outputs.push(output_n)

    return outputs

process_output_n = (output_n, exec_count, blob_store) ->
    if not output_n?
        return
    if output_n.text?
        output_n.text = diff_friendly(output_n.text)
    if output_n.data?
        for k, v of output_n.data
            if k.slice(0,5) == 'text/'
                output_n.data[k] = diff_friendly(output_n.data[k])
            if misc.startswith(k, 'image/')
                if blob_store?
                    value = blob_store.get_ipynb(v)
                    if not value?
                        # The image is no longer known; this could happen if the user reverts in the history
                        # browser and there is an image in the output that was not saved in the latest version.
                        # TODO: instead return an error.
                        return
                    output_n.data[k] = value
                else
                    return  # impossible to include in the output without blob_store
        output_n.output_type = "execute_result"
        output_n.metadata = {}
        output_n.execution_count = exec_count
    else if output_n.name?
        output_n.output_type = 'stream'
        if output_n.name == 'input'
            process_stdin_output(output_n)
    else if output_n.ename?
        output_n.output_type = 'error'
    return

process_stdin_output = (output) ->
    output.cocalc = misc.deep_copy(output)
    output.name = 'stdout'
    output.text = output.opts.prompt + ' ' + (output.value ? '')
    delete output.opts
    delete output.value

# Transform a string s with newlines into an array v of strings
# such that v.join('') == s.
diff_friendly = (s) ->
    if typeof(s) != 'string'  # might already be an array or undefined.
        return s
    v = s.split('\n')
    for i in [0...v.length-1]
        v[i] += '\n'
    if v[v.length-1] == ''
        v.pop()  # remove last elt
    return v

