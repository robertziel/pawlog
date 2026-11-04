// CI: `make test` (collector, ClickHouse rollups, tracker, dashboard) in throwaway containers,
// reported to GitHub as the commit status "jenkins/test". See docs/ci_jenkins.md.
//
// Nothing deployment-specific lives here; the Jenkins side supplies (global env / credentials):
//   JENKINS_HOME_VOLUME   name of the Docker volume mounted at JENKINS_HOME (the workspace lives in it)
//   github-pat            Secret Text credential with `repo:status`; statuses carry no link to this Jenkins
// A missing value fails the build.

pipeline {
  agent any

  options {
    timestamps()
    disableConcurrentBuilds()
    timeout(time: 60, unit: 'MINUTES')
    buildDiscarder(logRotator(numToKeepStr: '50'))
  }

  triggers { githubPush() }

  stages {
    stage('Checkout') {
      steps {
        checkout scm
        script {
          env.GIT_SHA = sh(script: 'git rev-parse HEAD', returnStdout: true).trim()
          // owner/repo from the remote this job checked out; never hardcoded
          env.GH_REPO = sh(script: "git config --get remote.origin.url | sed -E 's#^.*github.com[:/]##; s#\\.git\$##'", returnStdout: true).trim()
          if (!env.GH_REPO.contains('/')) { error "cannot derive owner/repo from the checkout remote" }
          if (!env.JENKINS_HOME_VOLUME) { error "JENKINS_HOME_VOLUME is not set" }
          // Sibling containers bind-mount from the Docker host, not from this container's filesystem.
          def vol = sh(script: 'docker volume inspect "$JENKINS_HOME_VOLUME" -f "{{.Mountpoint}}"', returnStdout: true).trim()
          env.SRC = vol + env.WORKSPACE.substring(env.JENKINS_HOME.length())
          echo "Building ${env.GIT_SHA} of ${env.GH_REPO}; host path ${env.SRC}"
        }
        notifyGitHub('jenkins/test', 'pending', 'make test running')
      }
    }

    stage('Test') {
      // make is not in the Jenkins image: run it in a docker-cli container. The checkout is mounted at its host
      // path, so bind mounts made by the Makefile (docker run -v $SRC/...) resolve on the host.
      steps {
        sh '''
          docker run --rm -e SRC -v /var/run/docker.sock:/var/run/docker.sock -v "$SRC":"$SRC" -w "$SRC" \
            docker:27-cli sh -c 'apk add -q --no-cache make python3 bash && make test SRC="$SRC"'
        '''
      }
      post {
        success  { notifyGitHub('jenkins/test', 'success', 'make test passed') }
        failure  { notifyGitHub('jenkins/test', 'failure', 'make test failed') }
        unstable { notifyGitHub('jenkins/test', 'failure', 'make test unstable') }
        aborted  { notifyGitHub('jenkins/test', 'error',   'Build aborted') }
      }
    }
  }

  post {
    cleanup {
      // the test containers write into the bind-mounted checkout as root
      sh 'docker run --rm -v "$SRC":/w alpine chown -R "$(id -u):$(id -g)" /w || true'
      sh 'true'
      cleanWs()
    }
  }
}

// Commit status via the REST API (the github-checks plugin silently no-ops without a GitHub App).
void notifyGitHub(String context, String state, String description) {
  if (!env.GIT_SHA || !env.GH_REPO) { echo "No sha/repo yet — skipping status (${state})"; return }
  try {
    withCredentials([string(credentialsId: 'github-pat', variable: 'GH_TOKEN')]) {
      writeFile file: '.github-status.json', text: groovy.json.JsonOutput.toJson([
        state: state, description: description, context: context])  // no target_url: the status never links to the CI host
      def code = sh(returnStdout: true, script: '''
        set +x
        curl -sS -o /dev/null -w '%{http_code}' -X POST \
          -H "Authorization: Bearer $GH_TOKEN" -H "Accept: application/vnd.github+json" \
          --data @.github-status.json "https://api.github.com/repos/$GH_REPO/statuses/$GIT_SHA"
      ''').trim()
      echo code == '201' ? "status '${state}' published" : "status '${state}' rejected (HTTP ${code}) — check github-pat"
    }
  } catch (err) {
    echo "Could not publish status '${state}': ${err.message}"
  } finally {
    sh 'rm -f .github-status.json || true'
  }
}
