data "aws_iam_policy_document" "ec2_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "docker_agent" {
  name               = "${var.name_prefix}-docker-agent"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

resource "aws_iam_role_policy" "platform_apply" {
  name   = "${var.name_prefix}-docker-agent-platform-apply"
  role   = aws_iam_role.docker_agent.id
  policy = file("${path.module}/policies/platform-apply.json")
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.docker_agent.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "docker_agent" {
  name = "${var.name_prefix}-docker-agent"
  role = aws_iam_role.docker_agent.name
}
