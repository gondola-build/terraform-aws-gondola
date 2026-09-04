# v0.1 single-fleet state migration. Apply once with the legacy variables before
# switching to the fleets map so these resources retain their identities.
moved {
  from = data.aws_ssm_parameter.runner_ami[0]
  to   = data.aws_ssm_parameter.runner_ami["default"]
}

moved {
  from = aws_security_group.runner[0]
  to   = aws_security_group.runner["default"]
}

moved {
  from = aws_iam_role.runner
  to   = aws_iam_role.runner["default"]
}

moved {
  from = aws_iam_instance_profile.runner
  to   = aws_iam_instance_profile.runner["default"]
}

moved {
  from = aws_launch_template.runner
  to   = aws_launch_template.runner["default"]
}
