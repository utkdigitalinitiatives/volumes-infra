# Shared Packer plugin requirements.
#
# Unlike lib-main-infra there is only one template here. The base image
# (drupal-base-rocky-linux-9) is built and owned by lib-main-infra; this repo
# only builds the app image on top of it. See README.md > Shared base image.

packer {
  required_plugins {
    azure = {
      source  = "github.com/hashicorp/azure"
      version = "~> 2.0"
    }
    ansible = {
      source  = "github.com/hashicorp/ansible"
      version = "~> 1.1"
    }
  }
}
