terraform { required_version = ">= 1.7.0" }
variable "environment" { type = string }
output "module_contract" { value = "disaster-recovery" }
