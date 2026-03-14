source "docker" "arm64" {
  changes     = [
    "EXPOSE 22",
    "CMD [\"/usr/sbin/sshd\", \"-D\"]",
    "WORKDIR /working-dir",
    "ENTRYPOINT [\"./bin/test\"]"
  ]
  commit      = "true"
  image       = "debian:12-slim"
  run_command = ["-d", "-i", "-t", "-v", "/var/run/docker.sock:/var/run/docker.sock", "--name", "packer-hermes-builder-arm64", "{{.Image}}", "/bin/bash"]
  platform    = "linux/arm64/v8"
}

source "docker" "amd64" {
  changes     = [
    "EXPOSE 22",
    "CMD [\"/usr/sbin/sshd\", \"-D\"]",
    "WORKDIR /working-dir",
    "ENTRYPOINT [\"./bin/test\"]"
  ]
  commit      = "true"
  image       = "debian:12-slim"
  run_command = ["-d", "-i", "-t", "-v", "/var/run/docker.sock:/var/run/docker.sock", "--name", "packer-hermes-builder-amd64", "{{.Image}}", "/bin/bash"]
  platform    = "linux/amd64"
}

build {
  sources = [
    "source.docker.arm64",
    "source.docker.amd64",
  ]

  provisioner "shell" {
    script = "bin/setup-image-requirements"
  }

  provisioner "ansible" {
    extra_arguments = ["--extra-vars", "ansible_host=packer-hermes-builder-${source.name} ansible_connection=docker"]
    playbook_file   = "infrastructure/ansible/playbook-builder.yml"
    user            = "root"
  }

  post-processor "docker-tag" {
    repository = "svanosselaer/hermes-builder"
    tags       = ["${source.name}"]
  }
}
