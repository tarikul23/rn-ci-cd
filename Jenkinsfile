#!/usr/bin/env groovy
// ---------------------------------------------------------------------------
// CI/CD for the rn-ci-cd solution (Jenkins declarative pipeline).
//
// Mirrors the GitHub Actions setup documented in DEPLOYMENT.md:
//
//   CI   restore -> build -> test the whole solution
//   CD   deploy only the applications whose files changed, each in its own lane
//
//        detect --+-- [approve] publish web -- deploy web   (mvc web/)
//                 +-- [approve] publish api -- deploy api   (web api/)
//                 +-- [approve] publish sso -- deploy sso   (SSO/)
//                 +-- [approve] publish svc -- deploy svc   (WindowsService/)
//
//   A change in the shared Domain/ project redeploys all four applications.
//   Deployment only happens on the branches listed in DEPLOY_BRANCHES.
//
// Setup (agents, deploy paths, approvers, credentials): see JENKINS.md.
// ---------------------------------------------------------------------------

pipeline {
    agent none

    options {
        timestamps()
        buildDiscarder(logRotator(numToKeepStr: '30', artifactNumToKeepStr: '10'))
        // One deploy at a time per branch - never interrupt an in-flight deploy.
        disableConcurrentBuilds()
        timeout(time: 4, unit: 'HOURS')
    }

    // Every push builds this branch.
    //   githubPush  fires the moment GitHub delivers a webhook. Needs Jenkins to
    //               be reachable from github.com - see JENKINS.md.
    //   pollSCM     asks GitHub for new commits every ~2 minutes. This is what
    //               actually works while Jenkins is only on localhost.
    // Both are declared: whichever can reach the repo first starts the build,
    // and Jenkins will not run the same commit twice.
    //
    // NOTE: a declarative `triggers` block is registered when the job runs, so
    // build the job once by hand after adding it - only then does it self-start.
    triggers {
        githubPush()
        pollSCM('H/2 * * * *')
    }

    parameters {
        choice(
            name: 'APPLICATION',
            choices: ['auto-detect', 'dashboard-web', 'mjh-api', 'dashboard-sso', 'windows-service'],
            description: 'auto-detect deploys whatever changed in this commit. Pick one application to force-deploy just that one (requires CONFIRM_DEPLOY).'
        )
        booleanParam(
            name: 'CONFIRM_DEPLOY',
            defaultValue: false,
            description: 'Required when APPLICATION is not auto-detect: confirms a forced deployment of this branch.'
        )
        string(
            name: 'BUILD_AGENT_LABEL',
            defaultValue: 'dotnet',
            description: 'Agent label for restore/build/test/publish. Needs the .NET 8 and .NET 10 SDKs.'
        )
        string(
            name: 'DEPLOY_AGENT_LABEL',
            defaultValue: 'windows',
            description: 'Agent label for the deploy steps. Must be a Windows agent with access to the deploy paths.'
        )
    }

    environment {
        SOLUTION_FILE       = 'rn-ci-cd.sln'
        BUILD_CONFIGURATION = 'Release'
        // Branches that are allowed to deploy. Everything else is CI-only.
        DEPLOY_BRANCHES     = 'dev,staging,hotfix'
        // Quieter, faster dotnet CLI.
        DOTNET_CLI_TELEMETRY_OPTOUT       = 'true'
        DOTNET_NOLOGO                     = 'true'
        DOTNET_SKIP_FIRST_TIME_EXPERIENCE = 'true'
    }

    stages {

        // -------------------------------------------------------------------
        // CI - build and test the solution, then work out what to deploy.
        // -------------------------------------------------------------------
        stage('CI - Build & Test') {
            agent { label params.BUILD_AGENT_LABEL }
            steps {
                script {
                    validateTrigger()

                    echo "SDKs available on ${env.NODE_NAME}:"
                    runCmd('dotnet --list-sdks')

                    runCmd("dotnet restore \"${env.SOLUTION_FILE}\"")
                    runCmd("dotnet build \"${env.SOLUTION_FILE}\" --configuration ${env.BUILD_CONFIGURATION} --no-restore")

                    if (hasTestProjects()) {
                        runCmd("dotnet test \"${env.SOLUTION_FILE}\" --configuration ${env.BUILD_CONFIGURATION} --no-build " +
                               "--verbosity normal --logger \"trx;LogFileName=test-results.trx\"")
                    } else {
                        echo 'No test projects found in the solution - skipping. Add one to enable tests.'
                    }

                    detectChanges()
                }
            }
            post {
                always {
                    archiveArtifacts artifacts: '**/test-results.trx', allowEmptyArchive: true, fingerprint: false
                }
            }
        }

        // -------------------------------------------------------------------
        // CD - four independent lanes. A rejection or failure in one lane never
        // blocks the others (failFast is off), matching the Actions layout.
        // -------------------------------------------------------------------
        stage('CD - Publish & Deploy') {
            when { expression { env.DEPLOY_ANY == 'true' } }
            parallel {

                stage('Dashboard Web') {
                    when { expression { env.DEPLOY_WEB == 'true' } }
                    stages {
                        stage('Approve Web') {
                            agent none
                            steps { script { approveApp('web') } }
                        }
                        stage('Publish Web') {
                            agent { label params.BUILD_AGENT_LABEL }
                            steps { script { publishApp('web') } }
                        }
                        stage('Deploy Web') {
                            agent { label params.DEPLOY_AGENT_LABEL }
                            steps { script { deployApp('web') } }
                        }
                    }
                }

                stage('MJH API') {
                    when { expression { env.DEPLOY_API == 'true' } }
                    stages {
                        stage('Approve API') {
                            agent none
                            steps { script { approveApp('api') } }
                        }
                        stage('Publish API') {
                            agent { label params.BUILD_AGENT_LABEL }
                            steps { script { publishApp('api') } }
                        }
                        stage('Deploy API') {
                            agent { label params.DEPLOY_AGENT_LABEL }
                            steps { script { deployApp('api') } }
                        }
                    }
                }

                stage('Dashboard SSO') {
                    when { expression { env.DEPLOY_SSO == 'true' } }
                    stages {
                        stage('Approve SSO') {
                            agent none
                            steps { script { approveApp('sso') } }
                        }
                        stage('Publish SSO') {
                            agent { label params.BUILD_AGENT_LABEL }
                            steps { script { publishApp('sso') } }
                        }
                        stage('Deploy SSO') {
                            agent { label params.DEPLOY_AGENT_LABEL }
                            steps { script { deployApp('sso') } }
                        }
                    }
                }

                stage('Windows Service') {
                    when { expression { env.DEPLOY_SVC == 'true' } }
                    stages {
                        stage('Approve SVC') {
                            agent none
                            steps { script { approveApp('svc') } }
                        }
                        stage('Publish SVC') {
                            agent { label params.BUILD_AGENT_LABEL }
                            steps { script { publishApp('svc') } }
                        }
                        stage('Deploy SVC') {
                            agent { label params.DEPLOY_AGENT_LABEL }
                            steps { script { deployApp('svc') } }
                        }
                    }
                }
            }
        }
    }

    post {
        success  { script { echo "Build ${env.BUILD_NUMBER} finished: ${deploySummary()}" } }
        unstable { script { echo "Build ${env.BUILD_NUMBER} unstable: ${deploySummary()}" } }
        failure  { echo "Build ${env.BUILD_NUMBER} failed. Check the stage view for the lane that broke." }
        aborted  { echo "Build ${env.BUILD_NUMBER} aborted - an approval was rejected or timed out." }
    }
}

// ===========================================================================
// Application catalog - one entry per deployable application.
//   dir      source folder watched for changes
//   project  csproj passed to `dotnet publish`
//   key      prefix of the Jenkins settings for this app (WEB_DEPLOY_PATH, ...)
//   out      publish output folder / stash contents
// ===========================================================================
def appCatalog() {
    return [
        web: [name: 'Dashboard Web',   dir: 'mvc web',        project: 'mvc web/DevOps.csproj',
              key: 'WEB', out: 'publish/web', manual: 'dashboard-web',
              excludeFiles: 'appsettings.json,appsettings.*.json', excludeDirs: 'uploads'],
        api: [name: 'MJH API',         dir: 'web api',        project: 'web api/web api.csproj',
              key: 'API', out: 'publish/api', manual: 'mjh-api',
              excludeFiles: 'appsettings.json,appsettings.*.json', excludeDirs: 'uploads'],
        sso: [name: 'Dashboard SSO',   dir: 'SSO',            project: 'SSO/SSO.csproj',
              key: 'SSO', out: 'publish/sso', manual: 'dashboard-sso',
              excludeFiles: 'appsettings.json,appsettings.*.json', excludeDirs: 'uploads'],
        svc: [name: 'Windows Service', dir: 'WindowsService', project: 'WindowsService/WindowsService.csproj',
              key: 'SVC', out: 'publish/svc', manual: 'windows-service',
              excludeFiles: 'appsettings.json,appsettings.*.json', excludeDirs: '']
    ]
}

// The shared library: a change here fans out to every application.
def sharedDir() { return 'Domain' }

// ---------------------------------------------------------------------------
// Cross-platform command helpers - the build agent may be Linux or Windows,
// the deploy agent is always Windows.
// ---------------------------------------------------------------------------
def runCmd(String cmd) {
    if (isUnix()) { sh script: cmd } else { powershell script: cmd }
}

def runCmdOutput(String cmd) {
    return (isUnix() ? sh(script: cmd, returnStdout: true)
                     : powershell(script: cmd, returnStdout: true)).trim()
}

def runCmdStatus(String cmd) {
    return isUnix() ? sh(script: cmd, returnStatus: true)
                    : powershell(script: "\$ErrorActionPreference='Continue'; ${cmd}; exit \$LASTEXITCODE", returnStatus: true)
}

// A test project is any project in the solution whose name mentions "test".
def hasTestProjects() {
    def projects = runCmdOutput("dotnet sln \"${env.SOLUTION_FILE}\" list")
    return projects.readLines().any { it.toLowerCase().trim().endsWith('.csproj') && it.toLowerCase().contains('test') }
}

// ---------------------------------------------------------------------------
// Trigger validation - what is allowed to cause a deployment.
// ---------------------------------------------------------------------------
def validateTrigger() {
    env.TARGET_BRANCH = (env.BRANCH_NAME?.trim()) ?: runCmdOutput('git rev-parse --abbrev-ref HEAD')
    echo "Branch: ${env.TARGET_BRANCH}"

    // A forced single-application deploy must be confirmed on the build form.
    if (params.APPLICATION != 'auto-detect' && !params.CONFIRM_DEPLOY) {
        error("Deployment cancelled: APPLICATION is '${params.APPLICATION}' but CONFIRM_DEPLOY was not ticked. Nothing was published and no file was copied to a server.")
    }

    if (!(env.CD_APPROVERS ?: '').trim()) {
        echo 'WARNING: CD_APPROVERS is not set - any Jenkins user who can see this build may approve a deployment. Set it as a Jenkins global property to restrict approvals.'
    }
}

// ---------------------------------------------------------------------------
// Change detection. Diffs this commit against the previous successful build
// (falling back to the first parent, like the Actions workflow) and raises a
// deploy flag per application. Domain/** fans out to all four.
// ---------------------------------------------------------------------------
def detectChanges() {
    def apps  = appCatalog()
    def flags = [web: false, api: false, sso: false, svc: false]

    def branchAllowed = env.DEPLOY_BRANCHES.split(',').collect { it.trim() }.contains(env.TARGET_BRANCH)

    if (!branchAllowed) {
        echo "Branch '${env.TARGET_BRANCH}' is not a deploy branch (${env.DEPLOY_BRANCHES}) - CI only."
    }
    else if (params.APPLICATION != 'auto-detect') {
        def entry = apps.find { k, v -> v.manual == params.APPLICATION }
        flags[entry.key] = true
        echo "Manual deployment requested: ${entry.value.name} -> ${env.TARGET_BRANCH}"
    }
    else {
        def base = resolveDiffBase()
        if (!base) {
            echo 'No commit to diff against (shallow clone, or first commit on the branch) - nothing will be deployed. Re-run with APPLICATION set to force a deploy.'
        } else {
            def changed = splitLines(runCmdOutput("git diff --name-only ${base} HEAD"))
            echo "Changed files since ${base}:\n  " + changed.join('\n  ')

            def sharedChanged = changed.any { it.startsWith(sharedDir() + '/') }
            if (sharedChanged) {
                echo "${sharedDir()}/ changed - redeploying every application."
            }
            apps.each { k, app ->
                flags[k] = sharedChanged || changed.any { it.startsWith(app.dir + '/') }
            }
        }
    }

    env.DEPLOY_WEB = flags.web.toString()
    env.DEPLOY_API = flags.api.toString()
    env.DEPLOY_SSO = flags.sso.toString()
    env.DEPLOY_SVC = flags.svc.toString()
    env.DEPLOY_ANY = flags.any { k, v -> v }.toString()

    echo "Deploy plan: ${deploySummary()}"
}

// Trimmed, non-empty lines. Kept @NonCPS: the CPS transformer does not support
// the spread operator, and this keeps the list handling out of the CPS engine.
@NonCPS
def splitLines(String text) {
    return text.readLines().collect { it.trim() }.findAll { it }
}

// Previous successful build's commit if Jenkins knows it, else the first parent.
def resolveDiffBase() {
    def candidates = [env.GIT_PREVIOUS_SUCCESSFUL_COMMIT, 'HEAD^'].findAll { it }
    for (c in candidates) {
        if (runCmdStatus("git cat-file -e ${c}^{commit}") == 0) { return c }
    }
    return null
}

def deploySummary() {
    def on = appCatalog().findAll { k, v -> env."DEPLOY_${k.toUpperCase()}" == 'true' }.collect { k, v -> v.name }
    return on ? on.join(', ') : 'no application deployed'
}

// ---------------------------------------------------------------------------
// Approval gate - runs before the build, so a reviewer signs off on the change
// rather than on an artifact that is already sitting on disk. Held on `agent
// none` so a waiting approval does not occupy an executor.
// ---------------------------------------------------------------------------
def approveApp(String key) {
    def app = appCatalog()[key]

    if ((env.REQUIRE_APPROVAL ?: 'true').toLowerCase() == 'false') {
        echo "REQUIRE_APPROVAL=false - deploying ${app.name} without a manual gate."
        return
    }

    def approvers = (env.CD_APPROVERS ?: '').trim()
    def waitMins  = (env.APPROVAL_TIMEOUT_MINUTES ?: '60') as Integer

    timeout(time: waitMins, unit: 'MINUTES') {
        def approver = input(
            message: "Deploy ${app.name} to '${env.TARGET_BRANCH}'?",
            ok: 'Deploy',
            submitter: approvers ?: null,
            submitterParameter: 'APPROVER'
        )
        echo "${app.name} approved by ${approver}."
    }
}

// ---------------------------------------------------------------------------
// Publish - framework-dependent `dotnet publish`, archived for traceability and
// stashed so the Windows deploy agent copies exactly what was built here.
// ---------------------------------------------------------------------------
def publishApp(String key) {
    def app = appCatalog()[key]

    runCmd("dotnet publish \"${app.project}\" --configuration ${env.BUILD_CONFIGURATION} --output \"${app.out}\"")

    archiveArtifacts artifacts: "${app.out}/**", fingerprint: true
    stash name: "artifact-${key}", includes: "${app.out}/**"
    echo "Published ${app.name} to ${app.out}"
}

// ---------------------------------------------------------------------------
// Deploy - mirror the published output onto the target with
// jenkins/deploy-app.ps1 (robocopy /MIR, preserving the excluded paths).
// ---------------------------------------------------------------------------
def deployApp(String key) {
    def app = appCatalog()[key]

    def dest = resolveSetting("${app.key}_DEPLOY_PATH")
    if (!dest) {
        error("${app.key}_DEPLOY_PATH is not configured for branch '${env.TARGET_BRANCH}'. See JENKINS.md.")
    }

    def excludeFiles = resolveSetting("${app.key}_EXCLUDE_FILES", app.excludeFiles)
    def excludeDirs  = resolveSetting("${app.key}_EXCLUDE_DIRS",  app.excludeDirs)
    // Only the Windows Service is stopped and started around the copy.
    def serviceName  = (key == 'svc') ? resolveSetting("${app.key}_SERVICE_NAME", '') : ''

    echo "Deploying ${app.name} (branch '${env.TARGET_BRANCH}') to '${dest}'"
    unstash "artifact-${key}"

    def credsId = (env.DEPLOY_CREDENTIALS_ID ?: '').trim()
    if (credsId) {
        withCredentials([usernamePassword(credentialsId: credsId,
                                          usernameVariable: 'DEPLOY_USER',
                                          passwordVariable: 'DEPLOY_PASSWORD')]) {
            runDeployScript(app, dest, excludeFiles, excludeDirs, serviceName, true)
        }
    } else {
        runDeployScript(app, dest, excludeFiles, excludeDirs, serviceName, false)
    }
}

def runDeployScript(Map app, String dest, String excludeFiles, String excludeDirs, String serviceName, boolean withCreds) {
    def args = [
        "-Source '${psQuote(app.out)}'",
        "-Destination '${psQuote(dest)}'",
        "-AppName '${psQuote(app.name)}'",
        "-ExcludeFiles '${psQuote(excludeFiles ?: '')}'",
        "-ExcludeDirs '${psQuote(excludeDirs ?: '')}'",
        "-ServiceName '${psQuote(serviceName ?: '')}'"
    ]
    // Credentials are read from the environment inside PowerShell, so the
    // password is never part of the command line that Jenkins logs.
    if (withCreds) {
        args << '-DeployUser $env:DEPLOY_USER' << '-DeployPassword $env:DEPLOY_PASSWORD'
    }
    powershell script: "& '.\\jenkins\\deploy-app.ps1' " + args.join(' ')
}

// Escape single quotes for a PowerShell single-quoted string literal.
def psQuote(String value) { return (value ?: '').replace("'", "''") }

// ---------------------------------------------------------------------------
// Settings lookup: <KEY>_<BRANCH> first, then <KEY>, read from the Jenkins
// environment (global or folder properties, or job env) and finally from the
// optional jenkins/deploy-targets.properties file in the repo.
//   e.g. WEB_DEPLOY_PATH_DEV  ->  WEB_DEPLOY_PATH
// ---------------------------------------------------------------------------
def resolveSetting(String key, String fallback = null) {
    def suffix = (env.TARGET_BRANCH ?: '').replaceAll('[^A-Za-z0-9]', '_').toUpperCase()
    def names  = suffix ? ["${key}_${suffix}", key] : [key]

    for (n in names) {
        def v = env."${n}"
        if (v?.trim()) { return v.trim() }
    }

    def props = loadTargetProperties()
    for (n in names) {
        def v = props[n]
        if (v?.trim()) { return v.trim() }
    }
    return fallback
}

// Parsed by hand rather than with readProperties: the Java properties format
// treats a backslash as an escape character, which would mangle Windows paths
// such as D:\DevOps\dev\web.
@NonCPS
def parseProperties(String text) {
    def map = [:]
    text.readLines().each { line ->
        def t = line.trim()
        if (!t || t.startsWith('#') || t.startsWith(';') || !t.contains('=')) { return }
        def i = t.indexOf('=')
        map[t.substring(0, i).trim()] = t.substring(i + 1).trim()
    }
    return map
}

def loadTargetProperties() {
    def path = 'jenkins/deploy-targets.properties'
    if (!fileExists(path)) { return [:] }
    return parseProperties(readFile(path))
}
