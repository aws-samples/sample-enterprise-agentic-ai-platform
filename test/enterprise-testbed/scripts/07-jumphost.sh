#!/usr/bin/env bash
# 07 — Optional SSM jumphost for reaching the platform's INTERNAL-only services
# (e.g. the private Langfuse ALB) from a laptop via SSM port-forwarding.
# Reads the VPC id + a private subnet from the enterprise-vpc fixture.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VPC_DIR="$HERE/enterprise-vpc"
JUMP_DIR="$HERE/jumphost"
AUTO="${1:-}"

echo "=== 07 — SSM jumphost ($JUMP_DIR) ==="

VPC_ID=$(cd "$VPC_DIR" && terraform output -raw vpc_id)
# First private subnet from the VPC fixture (jumphost gets no public IP).
JUMP_SUBNET=$(cd "$VPC_DIR" && terraform output -json private_subnet_ids | sed -E 's/^\["([^"]+)".*/\1/')

cd "$JUMP_DIR"
terraform init -input=false >/dev/null
terraform plan -input=false -out=tfplan \
  -var "vpc_id=$VPC_ID" -var "subnet_id=$JUMP_SUBNET"

if [ "$AUTO" != "--yes" ]; then
  read -r -p "Apply? Launches a t4g.micro SSM jumphost (billable). [type 'yes']: " ans
  [ "$ans" = "yes" ] || { echo "aborted."; rm -f tfplan; exit 1; }
fi

terraform apply -input=false tfplan
rm -f tfplan

echo ""
echo "Jumphost ready. To reach the private Langfuse ALB, port-forward via SSM:"
echo ""
terraform output -raw ssm_port_forward_hint
echo ""
echo "Replace <internal-alb-dns> with the platform's langfuse host and <port> with 3000:"
echo "  cd ../../../platform/eap-platform && terraform output -raw langfuse_base_url"
echo ""
echo "Requires the Session Manager plugin locally:"
echo "  session-manager-plugin --version || brew install --cask session-manager-plugin"
