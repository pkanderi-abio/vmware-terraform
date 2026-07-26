variable "name" {
  type = string
}

variable "folder" {
  type    = string
  default = null
}

variable "resource_pool_id" {
  type = string
}

variable "datastore_id" {
  type = string
}

variable "network_id" {
  type = string
}

variable "template_uuid" {
  type = string
}

variable "num_cpus" {
  type = number
}

variable "memory_mb" {
  type = number
}

variable "disk_gb" {
  type = number
}

variable "userdata" {
  description = "Rendered cloud-init user-data (plain text, not yet base64-encoded)."
  type        = string
}

variable "metadata" {
  description = "Rendered cloud-init meta-data (plain text, not yet base64-encoded)."
  type        = string
}
