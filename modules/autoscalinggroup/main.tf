data "aws_region" "_" {}

locals {
  # Validate the autoscaling group types
  autoscalinggroup_type = "${lookup(var.allowed_autoscalinggroup_types,var.autoscalinggroup_type)}"
}

locals {
  tags_asg_format = ["${null_resource.tags_as_list_of_maps.*.triggers}"]
  name            = "${var.name}"
}

resource "null_resource" "tags_as_list_of_maps" {
  count = "${(var.create ? 1 : 0 ) * length(keys(var.tags))}"

  triggers = "${map(
    "key", "${element(keys(var.tags), count.index)}",
    "value", "${element(values(var.tags), count.index)}",
    "propagate_at_launch", "true"
  )}"
}

data "template_file" "cloud_config_amazon" {
  template = "${file("${path.module}/amazon_ecs_ami.yml")}"

  vars {
    region                 = "${data.aws_region._.name}"
    name                   = "${local.name}"
    block_metadata_service = "${lookup(var.cluster_properties, "block_metadata_service", "0")}"
    efs_enabled            = "${lookup(var.cluster_properties, "efs_enabled", "0")}"
    efs_id                 = "${lookup(var.cluster_properties, "efs_id","")}"
    custom_userdata        = "${lookup(var.cluster_properties, "ec2_custom_userdata","")}"
  }
}

resource "aws_launch_configuration" "launch_config" {
  count = "${var.create ? 1 : 0 }"

  name_prefix   = "${local.name}-"
  image_id      = "${data.aws_ami.ecs_ami.id}"
  instance_type = "${lookup(var.cluster_properties, "ec2_instance_type")}"
  key_name      = "${lookup(var.cluster_properties, "ec2_key_name")}"

  security_groups = ["${var.vpc_security_group_ids}"]

  iam_instance_profile = "${var.iam_instance_profile}"

  user_data = "${data.template_file.cloud_config_amazon.rendered}"

  root_block_device {
    volume_size           = "15"
    volume_type           = "gp2"
    delete_on_termination = true
  }

  ebs_block_device {
    device_name           = "/dev/xvdcz"
    volume_size           = "${lookup(var.cluster_properties, "ec2_disk_size")}"
    volume_type           = "${lookup(var.cluster_properties, "ec2_disk_type")}"
    delete_on_termination = true
  }

  lifecycle {
    create_before_destroy = true
  }
}

locals {
  min_size        = "${local.min_size}"
  max_size        = "${local.max_size}"
  placement_group = "${local.placement_group}"
}

resource "aws_autoscaling_group" "this" {
  count = "${var.create && ( local.autoscalinggroup_type == "MIGRATION" || local.autoscalinggroup_type == "LEGACY" ) ? 1 : 0 }"
  name  = "${local.name}"

  launch_configuration = "${aws_launch_configuration.launch_config.name}"

  min_size        = "${lookup(var.cluster_properties, "ec2_asg_min")}"
  max_size        = "${lookup(var.cluster_properties, "ec2_asg_max")}"
  placement_group = "${lookup(var.cluster_properties, "ec2_placement_group", "")}"

  vpc_zone_identifier = [
    "${var.subnet_ids}",
  ]

  lifecycle {
    create_before_destroy = true
  }

  enabled_metrics = [
    "GroupMinSize",
    "GroupMaxSize",
    "GroupDesiredCapacity",
    "GroupInServiceInstances",
    "GroupPendingInstances",
    "GroupStandbyInstances",
    "GroupTerminatingInstances",
    "GroupTotalInstances",
  ]

  tags = ["${concat(
      list(map("key", "Name", "value", local.name, "propagate_at_launch", true)),
      local.tags_asg_format
   )}"]
}

resource "aws_cloudformation_stack" "autoscaling_group" {
  count = "${var.create && ( local.autoscalinggroup_type == "MIGRATION" || local.autoscalinggroup_type == "AUTOUPDATE" ) ? 1 : 0 }"
  name  = "${local.name}-cf"

  template_body = <<EOF
{
  "Resources": {
    "ASG": {
      "Type": "AWS::AutoScaling::AutoScalingGroup",
      "Properties": {
        "VPCZoneIdentifier": ["${var.subnet_ids}"]
        "LaunchConfigurationName": "${aws_launch_configuration.launch_config.name}"
        "MaxSize": "${local.max_size}",
        "MinSize": "${local.min_size}",
        "PlacementGroup" : "${local.local.placement_group}",
        "Tags": ["${concat(
        list(map("key", "Name", "value", local.name, "propagate_at_launch", true)),
        local.tags_asg_format
     )}"],
        "TerminationPolicies": ["OldestLaunchConfiguration", "OldestInstance"],
        "MetricsCollection": [
          {
            "Granularity": "1Minute",
            "Metrics": [
              "GroupMinSize",
              "GroupMaxSize",
              "GroupDesiredCapacity",
              "GroupInServiceInstances",
              "GroupPendingInstances",
              "GroupStandbyInstances",
              "GroupTerminatingInstances",
              "GroupTotalInstances"
            ]
            }
        ],
        "HealthCheckType": "EC2"
      },
      "UpdatePolicy": {
        "AutoScalingRollingUpdate": {
          "MinInstancesInService": "${local.min_size}",
          "MaxBatchSize": "1",
          "PauseTime": "PT15M"
          "WaitOnResourceSignals": "true"
        }
      }
    }
  },
  "Outputs": {
    "AsgName": {
      "Description": "The name of the auto scaling group",
       "Value": {"Ref": "${local.name}-cf"}
    }
  }
}
EOF
}
