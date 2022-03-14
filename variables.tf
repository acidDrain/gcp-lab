variable "project" {
  type        = string
  description = "The GCP project that deployment should target"
}

variable "region" {
  type        = string
  description = "The GCP region that deployment should target"
}

variable "num_instances" {
  type    = number
  default = 1
}

variable "network_tier" {
  type    = string
  default = "PREMIUM"
}

variable "credentials" {}

