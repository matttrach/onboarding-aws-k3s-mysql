# assumed resources that already exist:
# - vpc (set as default)
# - subnet in the VPC matching CIDR given https://us-west-1.console.aws.amazon.com/vpc/home?region=us-west-1#subnets
# - vpc security group, allowing only 22 & 8080 to your home IP 'curl ipinfo.io/ip' https://us-west-1.console.aws.amazon.com/ec2/v2/home?region=us-west-1#SecurityGroups:
# - ubuntu image
# - an ssh key in your agent that matches the public key given
locals {
    instance_type   = "t2.medium"
    user            = "matttrach"
    use             = "onboarding"
    security_group  = "sg-06bf73fa3affae222"
    vpc             = "vpc-3d1f335a"
    subnet          = "subnet-0835c74adb9e4a860"
    ami             = "ami-01f87c43e618bf8f0"
    mariadb_ami     = "ami-0465c51520ec9394f"
    names           = ["k3s0-mdb","k3s1-mdb","k3s2-mdb"]
    nodes           = toset(local.names)
    # public ssh key, BEWARE! changing this will destroy the servers!
    sshkey          = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGbArPa8DHRkmnIx+2kT/EVmdN1cORPCDYF2XVwYGTsp matt.trachier@suse.com"
 }

resource "random_uuid" "cluster_token" {
}

resource "aws_instance" "db" {
  ami                         = local.mariadb_ami
  instance_type               = local.instance_type
  vpc_security_group_ids      = [local.security_group]
  subnet_id                   = local.subnet
  associate_public_ip_address = true
  instance_initiated_shutdown_behavior = "terminate"
  user_data = <<-EOT
  #cloud-config
  disable_root: false
  users:
    - name: ${local.user}
      gecos: ${local.user}
      sudo: ALL=(ALL) NOPASSWD:ALL
      groups: users, admin
      ssh_authorized_keys:
        - ${local.sshkey}
  EOT

  tags = {
    Name = "mariadb"
    User = local.user
    Use  = local.use
  }

  connection {
    type        = "ssh"
    user        = local.user
    script_path = "/home/${local.user}/initial"
    agent       = true
    host        = self.public_ip
  }

  provisioner "remote-exec" {
    inline = [<<-EOT
      max_attempts=15
      attempts=0
      interval=5
      while [ "$(sudo cloud-init status)" != "status: done" ]; do
        echo "cloud init is \"$(sudo cloud-init status)\""
        attempts=$(expr $attempts + 1)
        if [ $attempts = $max_attempts ]; then break; fi
        sleep $interval;
      done
    EOT
    ]
  }
}

resource "aws_instance" "k3s" {
  for_each                    = local.nodes
  ami                         = local.ami
  instance_type               = local.instance_type
  vpc_security_group_ids      = [local.security_group]
  subnet_id                   = local.subnet
  associate_public_ip_address = true
  instance_initiated_shutdown_behavior = "terminate"
  user_data = <<-EOT
  #cloud-config
  disable_root: false
  users:
    - name: ${local.user}
      gecos: ${local.user}
      sudo: ALL=(ALL) NOPASSWD:ALL
      groups: users, admin
      ssh_authorized_keys:
        - ${local.sshkey}
  EOT

  tags = {
    Name = each.key
    User = local.user
    Use  = local.use
  }

  connection {
    type        = "ssh"
    user        = local.user
    script_path = "/home/${local.user}/initial"
    agent       = true
    host        = self.public_ip
  }

  provisioner "remote-exec" {
    inline = [<<-EOT
      max_attempts=15
      attempts=0
      interval=5
      while [ "$(sudo cloud-init status)" != "status: done" ]; do
        echo "cloud init is \"$(sudo cloud-init status)\""
        attempts=$(expr $attempts + 1)
        if [ $attempts = $max_attempts ]; then break; fi
        sleep $interval;
      done
    EOT
    ]
  }
}
resource "null_resource" "db" {
  depends_on = [
    aws_instance.db,
    aws_instance.k3s,
  ]
  connection {
    type        = "ssh"
    user        = local.user
    script_path = "/home/${local.user}/tfdb"
    agent       = true
    host        = aws_instance.db.public_ip
  }

  provisioner "remote-exec" {
    inline = [<<-EOT
      sudo mysql -e 'create database kubernetes;' || true
      sudo mysql -e 'GRANT ALL ON kubernetes.* TO root@"${aws_instance.k3s[local.names[0]].private_ip}" IDENTIFIED BY "${random_uuid.cluster_token.result}"';
      sudo mysql -e 'GRANT ALL ON kubernetes.* TO root@"${aws_instance.k3s[local.names[1]].private_ip}" IDENTIFIED BY "${random_uuid.cluster_token.result}"';
      sudo mysql -e 'GRANT ALL ON kubernetes.* TO root@"${aws_instance.k3s[local.names[2]].private_ip}" IDENTIFIED BY "${random_uuid.cluster_token.result}"';
      echo "[mysqld]\nskip-networking=0\nbind-address=0.0.0.0" > 98-bind.cnf
      sudo mv 98-bind.cnf /etc/mysql/mariadb.conf.d/98-bind.cnf
      sudo systemctl restart mysqld
      sleep 5
    EOT
    ]
  }
}

resource "null_resource" "bootstrap" {
  depends_on = [
    aws_instance.k3s,
    aws_instance.db,
    null_resource.db,
  ]
  for_each = toset([local.names[0]])
  connection {
    type        = "ssh"
    user        = local.user
    script_path = "/home/${local.user}/tfbootstrap"
    agent       = true
    host        = aws_instance.k3s[each.key].public_ip
  }

  provisioner "remote-exec" {
    inline = [<<-EOT
      sudo curl -sfL https://get.k3s.io | \
        INSTALL_K3S_VERSION=v1.21.6+k3s1 \
        INSTALL_K3S_EXEC="server --datastore-endpoint mysql://root:${random_uuid.cluster_token.result}@tcp(${aws_instance.db.private_ip}:3306)/kubernetes --write-kubeconfig-mode 644 --token ${random_uuid.cluster_token.result}" sh -
      sleep 15
      sudo k3s kubectl get node
    EOT
    ]
  }
}

resource "null_resource" "nodes" {
  depends_on = [
    aws_instance.k3s,
    aws_instance.db,
    null_resource.db,
    null_resource.bootstrap,
  ]
  for_each = toset([for n in local.names: n if n != local.names[0]])
  connection {
    type        = "ssh"
    user        = local.user
    script_path = "/home/${local.user}/tfnodes"
    agent       = true
    host        = aws_instance.k3s[each.key].public_ip
  }

  provisioner "remote-exec" {
    inline = [<<-EOT
      sudo curl -sfL https://get.k3s.io | \
        INSTALL_K3S_VERSION=v1.21.6+k3s1 \
        K3S_TOKEN=${random_uuid.cluster_token.result} \
        K3S_URL="https://${aws_instance.k3s[local.names[0]].public_dns}:6443" \
        INSTALL_K3S_EXEC="server --datastore-endpoint mysql://root:${random_uuid.cluster_token.result}@tcp(${aws_instance.db.private_ip}:3306)/kubernetes --write-kubeconfig-mode 644" sh -
      sleep 15
    EOT
    ]
  }
}

resource "null_resource" "validate" {
  depends_on = [
    aws_instance.k3s,
    aws_instance.db,
    null_resource.db,
    null_resource.bootstrap,
    null_resource.nodes,
  ]
  connection {
    type        = "ssh"
    user        = local.user
    script_path = "/home/${local.user}/tfvalidate"
    agent       = true
    host        = aws_instance.k3s[local.names[0]].public_ip
  }

  provisioner "remote-exec" {
    inline = [<<-EOT
      sudo k3s kubectl get node
    EOT
    ]
  }
}
