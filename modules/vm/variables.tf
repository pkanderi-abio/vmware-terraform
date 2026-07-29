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

variable "reserve_memory" {
  description = "Reserve 100% of memory (no ballooning/swapping). Intended for latency-sensitive roles like etcd control-plane nodes, not workers."
  type        = bool
  default     = false
}

variable "cpu_share_level" {
  description = "vSphere CPU shares level (low/normal/high) -- used instead of a hard MHz reservation, which isn't portable across heterogeneous hosts."
  type        = string
  default     = "normal"
}

variable "tag_ids" {
  description = "vSphere tag IDs to apply to this VM."
  type        = list(string)
  default     = []
}
