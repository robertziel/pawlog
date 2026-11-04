# Jenkins CI

Every pushed branch runs `make test` and reports commit status **`jenkins/test`** to GitHub.
The same `Jenkinsfile` serves the private mirror and the public repo; the repo is derived from the checkout remote.

Job: multibranch pipeline, source = the GitHub repo, script path `Jenkinsfile`, webhook `<jenkins>/github-webhook/`.

Jenkins needs (global environment / credentials; a missing one fails the build):

| name | what |
| --- | --- |
| `JENKINS_HOME_VOLUME` | Docker volume mounted at `JENKINS_HOME`. The Makefile's bind mounts (`SRC`) are resolved on the Docker host from it |
| `github-pat` | Secret Text, scope `repo:status` |

Jenkins needs the Docker CLI and the host socket (not `make`: the build runs it in a `docker:27-cli` container with the checkout mounted at its host path). Statuses carry no link to Jenkins.
