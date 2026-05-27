variable "subscription_id" {
  type = string
}

variable "location" {
  type    = string
  default = "Brazil South"
}

variable "resource_group_name" {
  type    = string
  default = "rg-netbird-lab"
}

variable "admin_username" {
  type    = string
  default = "vennecy"
}

variable "admin_password" {
  type      = string
  sensitive = true
}

variable "netbird_setup_key" {
  type      = string
  sensitive = true
}