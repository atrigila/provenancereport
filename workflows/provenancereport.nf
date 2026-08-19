/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    IMPORT MODULES / SUBWORKFLOWS / FUNCTIONS
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/
include { paramsSummaryMap                } from 'plugin/nf-schema'
include { QUARTONOTEBOOK                  } from '../modules/nf-core/quartonotebook/main'
include { REPORTENVIRONMENT               } from '../modules/local/reportenvironment/main'
include { REPORTENVIRONMENT as STAGE_FILE } from '../modules/local/reportenvironment/main'
include { MULTIQC                         } from '../modules/nf-core/multiqc/main'
include { paramsSummaryMultiqc            } from '../subworkflows/nf-core/utils_nfcore_pipeline'
include { softwareVersionsToYAML          } from '../subworkflows/nf-core/utils_nfcore_pipeline'
include { methodsDescriptionText          } from '../subworkflows/local/utils_nfcore_provenancereport_pipeline'

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    RUN MAIN WORKFLOW
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

workflow PROVENANCEREPORT {

    take:
    ch_samplesheet // channel: samplesheet read in from --input
    outdir

    main:

    def ch_versions = channel.empty()
    def report_notebook = file(params.notebook ?: "${projectDir}/assets/provenance_report.qmd", checkIfExists: true)
    document_file = params.document ? file(params.document) : channel.empty()

    ch_quarto_input = ch_samplesheet
        .collect(flat: false)
        .multiMap { rows ->
            def input_ids = rows.collect { meta, _input_file -> meta.id }
            def input_files = rows.collect { _meta, input_file -> input_file }
            def input_file_names = input_files.collect { input_file -> input_file.getName() }
            def report_meta = [
                id: report_notebook.baseName,
                report_file_name: report_notebook.baseName,
                input_ids: input_ids.join(','),
                input_files: input_file_names.join(','),
                input_file_count: input_file_names.size(),
            ]
            notebook:
            [
                report_meta,
                report_notebook,
            ]

            parameters:
            [
                input_dir: './',
                input_filename: input_file_names[0],
            ]

            input_files:
            input_files

            extensions:
            []
        }

    QUARTONOTEBOOK (
        ch_quarto_input.notebook,
        ch_quarto_input.parameters,
        ch_quarto_input.input_files,
        ch_quarto_input.extensions,
    )

    REPORTENVIRONMENT (report_notebook)

    //
    // Collate and save software versions
    //
    def report_environment_versions = REPORTENVIRONMENT.out.versions
        .map { _process, tool, version ->
            [ 'QUARTONOTEBOOK', "  ${tool}: ${version}" ]
        }
        .groupTuple(by:0)
        .map { process, tool_versions ->
            tool_versions.unique().sort()
            "${process}:\n${tool_versions.join('\n')}"
        }

    def ch_collated_versions = softwareVersionsToYAML(ch_versions)
        .mix(report_environment_versions)
        .collectFile(
            storeDir: "${outdir}/pipeline_info",
            name: 'nf_core_'  +  'provenancereport_software_'  + 'mqc_'  + 'versions.yml',
            sort: true,
            newLine: true
        )

    //
    // MODULE: MultiQC
    //
    def ch_multiqc_files = channel.empty()
    ch_multiqc_files = ch_multiqc_files.mix(ch_collated_versions)
    ch_multiqc_files = ch_multiqc_files.mix(
        channel.value(file(params.input, checkIfExists: true)).collectFile(name: 'samplesheet.csv')
    )

    def ch_summary_params = paramsSummaryMap(workflow, parameters_schema: 'nextflow_schema.json')
    def workflow_summary = paramsSummaryMultiqc(ch_summary_params)
        .readLines()
        .findAll { line -> !line.startsWith('description:') && !line.startsWith('section_href:') }
        .join('\n')
    ch_multiqc_files = ch_multiqc_files.mix(
        channel.value(workflow_summary).collectFile(name: 'workflow_summary_mqc.yaml')
    )

    def ch_methods_description = channel.value(
        methodsDescriptionText(file("${projectDir}/assets/methods_description_template.yml", checkIfExists: true))
    )
    ch_multiqc_files = ch_multiqc_files.mix(
        ch_methods_description.collectFile(name: 'methods_description_mqc.yaml', sort: true)
    )

    def ch_runtime_environment = REPORTENVIRONMENT.out.runtime_environment
        .map { process_name, container, r_session_info, python_version ->
            runtimeEnvironmentMultiqc(
                process_name,
                container,
                workflow.containerEngine,
                workflow.profile,
                r_session_info,
                python_version,
            )
        }
        .collectFile(name: 'runtime_environment_mqc.yaml', sort: true)
    ch_multiqc_files = ch_multiqc_files.mix(ch_runtime_environment)
    if (params.document) {
        def ch_traceability_document = channel.value(
            traceabilityDocumentMultiqc(document_file.getName(), document_file.toString())
        ).collectFile(name: 'traceability_document_mqc.yaml', sort: true)
        ch_multiqc_files = ch_multiqc_files.mix(ch_traceability_document)
    }

    MULTIQC (
        ch_multiqc_files.flatten().collect().map { files ->
            [
                [ id: 'provenancereport' ],
                files,
                file("${projectDir}/assets/multiqc_config.yml", checkIfExists: true),
                file("${projectDir}/assets/nf-core-provenancereport_logo_light.png", checkIfExists: true),
                [],
                [],
            ]
        }
    )

    STAGE_FILE(document_file)

    emit:
    versions       = ch_versions                                      // channel: [ path(versions.yml) ]
    reports        = QUARTONOTEBOOK.out.html                          // channel: [ val(meta), path(html) ]
    multiqc_report = MULTIQC.out.report.map { _meta, report -> report } // channel: path(multiqc_report.html)
    document       = STAGE_FILE.out.staged_file
}

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    FUNCTIONS
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

def escapeHtml(value) {
    return (value ?: 'Not available')
        .replace('&', '&amp;')
        .replace('<', '&lt;')
        .replace('>', '&gt;')
        .replace('"', '&quot;')
}

def runtimeEnvironmentMultiqc(process_name, container, container_engine, profile, r_session_info, python_version) {
    def process_text = escapeHtml(process_name)
    def container_text = escapeHtml(container)
    def engine_text = escapeHtml(container_engine ?: 'None')
    def profile_text = escapeHtml(profile ?: 'standard')
    def r_text = escapeHtml(r_session_info).replace('\n', '\n      ')
    def python_text = escapeHtml(python_version)

    return """
    id: 'nf-core-provenancereport-runtime-environment'
    description: 'Runtime environment used to render the Quarto report.'
    section_name: 'Report Runtime Environment'
    plot_type: 'html'
    data: |
      <dl class="dl-horizontal">
        <dt>Process</dt><dd><samp>${process_text}</samp></dd>
        <dt>Container engine</dt><dd><samp>${engine_text}</samp></dd>
        <dt>Container</dt><dd><samp>${container_text}</samp></dd>
        <dt>Nextflow profile</dt><dd><samp>${profile_text}</samp></dd>
        <dt>Python</dt><dd><samp>${python_text}</samp></dd>
      </dl>
      <h4>R sessionInfo()</h4>
      <pre>${r_text}</pre>
    """.stripIndent().trim()
}

def traceabilityDocumentMultiqc(document_name, document_path) {
    def document_name_text = escapeHtml(document_name)
    def document_path_text = escapeHtml(document_path)

    return """
    id: 'nf-core-provenancereport-traceability-document'
    description: 'Review sign-off document supplied for this provenance report run.'
    section_name: 'Traceability Document Review'
    plot_type: 'html'
    data: |
      <dl class="dl-horizontal">
        <dt>Document file</dt><dd><samp>${document_name_text}</samp></dd>
        <dt>Source path</dt><dd><samp>${document_path_text}</samp></dd>
      </dl>
    """.stripIndent().trim()
}

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    THE END
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/
