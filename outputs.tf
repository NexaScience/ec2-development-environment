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

output "enter_container" {
  description = "Command to enter the dev container after SSH"
  value       = "./enter-container.sh"
}

output "first_time_setup" {
  description = "First time setup: authenticate Claude inside the container"
  value       = "claude login"
}

output "app_clone_path" {
  description = "Path where the application repository is cloned on EC2"
  value       = "/home/ubuntu/app"
}

output "start_sessions" {
  description = "Command to start Claude remote-control sessions inside the container"
  value       = "~/scripts/start-claude-sessions.sh"
}
