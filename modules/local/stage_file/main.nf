process STAGE_FILE {
    tag 'stage file'
    label 'process_single'

    input:
    path(stage_file)

    output:
    path(stage_file), emit: staged_file

    script:
    """
    """
}