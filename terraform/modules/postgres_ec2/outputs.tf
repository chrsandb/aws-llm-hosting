output "private_ip" {
  value = aws_instance.this.private_ip
}

output "instance_id" {
  value = aws_instance.this.id
}

output "volume_id" {
  value = one(aws_instance.this.ebs_block_device).volume_id
}
