variable "zone_id" {
  description = "Cloudflare zone identifier that owns the managed DNS records."
  type        = string

  validation {
    condition     = can(regex("^[0-9a-f]{32}$", var.zone_id))
    error_message = "The Cloudflare zone ID must be a 32-character lowercase hexadecimal identifier."
  }
}

variable "zone_name" {
  description = "Authoritative DNS zone name appended to each relative record name."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)+$", var.zone_name))
    error_message = "The Cloudflare zone name must be a lowercase fully qualified domain name without a trailing dot."
  }
}

variable "origin_ipv4" {
  description = "Stable Elastic IPv4 address keyed by controller and worker role."
  type        = map(string)

  validation {
    condition = (
      length(var.origin_ipv4) == 2 &&
      alltrue([
        for role in ["controller", "worker"] :
        can(regex("^(?:[0-9]{1,3}\\.){3}[0-9]{1,3}$", var.origin_ipv4[role]))
      ])
    )
    error_message = "Origin addresses must contain explicit controller and worker IPv4 values."
  }
}

variable "records" {
  description = "Relative DNS names mapped to their EC2 origin role and Cloudflare proxy mode."
  type = map(object({
    role    = string
    proxied = optional(bool, true)
  }))

  validation {
    condition = (
      length(var.records) > 0 &&
      alltrue([
        for name, record in var.records :
        can(regex("^(?:\\*\\.)?[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)*$", name)) &&
        contains(["controller", "worker"], record.role)
      ])
    )
    error_message = "Each record must use a valid lowercase relative DNS name and target the controller or worker role."
  }
}
