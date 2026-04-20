resource "aws_instance" "main" {
  ami = local.ami_id
  instance_type = "t3.micro"
  vpc_security_group_ids = [local.sg_id]
  subnet_id = local.private_subnet_id

  tags = merge(
    local.common_tags, 
    {
        Name = "${var.project}-${var.env}-${var.component}"
    }
  )
}

resource "terraform_data" "main" {
  triggers_replace = [aws_instance.main.id]

  connection {
    type     = "ssh"
    user     = "ec2-user"
    password = "DevOps321"
    host     = aws_instance.main.private_ip
  }

  provisioner "file" {
    source = "bootstrap.sh"
    destination = "/tmp/bootstrap.sh"
  }

  provisioner "remote-exec" {
    inline = [ 
        "chmod +x /tmp/bootstrap.sh",
        "sudo sh /tmp/bootstrap.sh ${var.component}"
     ]
  }
}

resource "aws_ec2_instance_state" "main" {
  instance_id = aws_instance.main.id
  state       = "stopped"
  depends_on = [ terraform_data.main ]
}

resource "aws_ami_from_instance" "main" {
  name               = "${var.project}-${var.env}-${var.component}"
  source_instance_id = aws_instance.main.id
  depends_on = [ aws_ec2_instance_state.main ]
  tags = merge(
    local.common_tags, 
    {
        Name = "${var.project}-${var.env}-${var.component}"
    }
  )
}

resource "aws_lb_target_group" "main" {
  name        = "${var.project}-${var.env}-${var.component}"
  port        = local.port_number
  protocol    = "HTTP"
  vpc_id      = local.vpc_id
  deregistration_delay = 60

  health_check {
    healthy_threshold = 3
    unhealthy_threshold = 3
    interval = 10
    path = local.health_check_path
    port = local.port_number
    protocol = "HTTP"
    matcher = "200-299"
    timeout = 2
  }
}

resource "aws_launch_template" "main" {
  name = "${var.project}-${var.env}-${var.component}-v3"
  image_id = aws_ami_from_instance.main.id
  instance_type = "t3.micro"
  instance_initiated_shutdown_behavior = "terminate"
  vpc_security_group_ids = [ local.sg_id ]
  update_default_version = true

  tag_specifications {
    resource_type = "instance"

    tags = merge(
      local.common_tags, 
      {
        Name = "${var.project}-${var.env}-${var.component}"
      }
    )
  }

  tag_specifications {
    resource_type = "volume"

    tags = merge(
      local.common_tags, 
      {
        Name = "${var.project}-${var.env}-${var.component}"
      }
    )
  }

    tags = merge(
      local.common_tags, 
      {
        Name = "${var.project}-${var.env}-${var.component}-v3"
      }
    )
}

resource "aws_autoscaling_group" "main" {
  name                      = "${var.project}-${var.env}-${var.component}"
  max_size                  = 10
  min_size                  = 1
  health_check_grace_period = 120
  health_check_type         = "ELB"
  desired_capacity          = 1
  force_delete              = false

  launch_template {
    id      = aws_launch_template.main.id
    version = "$Latest"
  }

  vpc_zone_identifier = [ local.private_subnet_id ]
  target_group_arns = [ aws_lb_target_group.main.arn ]

  instance_refresh {
    strategy = "Rolling"
    preferences {
      min_healthy_percentage = 50
    }
    triggers = ["launch_template"]
  }

  dynamic "tag" {
    for_each = merge(
        {
            Name = "${var.project}-${var.env}-${var.component}"
        },
        local.common_tags
    )
    content {
      key                 = tag.key
      value               = tag.value
      propagate_at_launch = true
    }
  }

  # with in 15min autoscaling should be successful
  timeouts {
    delete = "15m"
  }
}

resource "aws_autoscaling_policy" "main" {
  autoscaling_group_name = aws_autoscaling_group.main.name
  name                   = "${var.project}-${var.env}-${var.component}"
  policy_type            = "TargetTrackingScaling"
  estimated_instance_warmup = 120

  target_tracking_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ASGAverageCPUUtilization"
    }
    target_value = 70.0
  }
}

resource "aws_lb_listener_rule" "main" {
  listener_arn = local.alb_listener_arn
  priority     = var.rule_priority

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.main.arn
  }

  condition {
    host_header {
      values = [local.host_header]
    }
  }
}

resource "terraform_data" "main_delete" {
  triggers_replace = [
    aws_instance.main.id
  ]
  depends_on = [aws_autoscaling_policy.main]
  
  # it executes in bastion
  provisioner "local-exec" {
    command = "aws ec2 terminate-instances --instance-ids ${aws_instance.main.id} "
  }
}
