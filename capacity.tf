variable "runner_instance_type_alternatives" {
  description = "Ordered, explicitly approved alternatives to runner_instance_type for the legacy fleet. Empty preserves the single-type launch behavior."
  type        = list(string)
  default     = []

  validation {
    condition = length(var.runner_instance_type_alternatives) <= 7 && length(distinct(var.runner_instance_type_alternatives)) == length(var.runner_instance_type_alternatives) && alltrue([
      for instance_type in var.runner_instance_type_alternatives : can(regex("^[a-z][a-z0-9-]{0,31}\\.[a-z0-9-]{1,31}$", instance_type))
    ])
    error_message = "runner_instance_type_alternatives accepts at most seven unique EC2 instance type names."
  }
}

locals {
  approved_instance_types = {
    for name, fleet in local.fleets : name => concat([fleet.instance_type], fleet.instance_type_alternatives)
    if length(fleet.instance_type_alternatives) > 0
  }
  fixed_type_fleets = {
    for name, fleet in local.fleets : name => fleet if !contains(keys(local.approved_instance_types), name)
  }
  approved_type_checks = {
    for candidate in flatten([
      for name, instance_types in local.approved_instance_types : [
        for index, instance_type in instance_types : { key = "${name}-${index}", fleet = name, instance_type = instance_type }
      ]
    ]) : candidate.key => candidate
  }
}

# Read only the operator's exact selections, and only for opted-in fleets. This
# checks architecture; it does not discover alternatives or query live capacity.
data "aws_ec2_instance_type" "approved" {
  for_each      = local.approved_type_checks
  instance_type = each.value.instance_type
}
