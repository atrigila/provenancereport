process REPORTENVIRONMENT {
    tag 'report runtime environment'
    label 'process_single'

    output:
    tuple val("${task.process}"),
          val("${task.container ?: 'Not configured'}"),
          eval("if command -v Rscript >/dev/null 2>&1; then Rscript -e 'sessionInfo()' 2>/dev/null || printf 'Not available\\n'; else printf 'Not available\\n'; fi"),
          eval("if command -v python >/dev/null 2>&1; then python --version 2>&1 || printf 'Not available\\n'; elif command -v python3 >/dev/null 2>&1; then python3 --version 2>&1 || printf 'Not available\\n'; else printf 'Not available\\n'; fi"),
          emit: runtime_environment

    script:
    """
    true
    """
}
