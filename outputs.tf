output "instance_id" {
  description = "EC2 instance ID"
  value       = aws_instance.claude_dev.id
}

output "public_ip" {
  description = "Public IP address of the instance"
  value       = aws_instance.claude_dev.public_ip
}

output "ssh_command" {
  description = "SSH command to connect to the instance"
  value       = "ssh ubuntu@${aws_instance.claude_dev.public_ip}"
}

output "first_time_setup" {
  description = "First time setup: authenticate Claude inside the container"
  value       = "claude login"
}

output "app_clone_path" {
  description = "Path where the application repository is cloned on EC2"
  value       = "/home/ubuntu/${basename(var.GIT_REPO_URL)}"
}

output "start_session" {
  description = "Command to start Claude remote-control session inside the container"
  value       = "~/scripts/start-claude-sessions.sh"
}
