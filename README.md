# mite: a terminal emulator

- idea: pass a file to save the data to? we can memory map it and just write directly to it? although, we might want more control as that could crash
- idea: if the buffer gets full, could re unmap the pages at the fromt and reuse them by mapping them to the end?

- buffer strategy
    - just keep allocating until the os stops giving us memory
    - once we can't allocate, we stop reading more data, what are our options?
        - option: start overwriting old data with new data
        - option: stop execution and notify the user
        - option: dump to a file?
        Maybe this is a configuration option that the user decides? Maybe the default behavior
        is to overwrite old data but the user can opt-in to pausing execution when this happens.
        "pause-on-oom"
