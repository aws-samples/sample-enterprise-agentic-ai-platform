#!/usr/bin/env bash
# 02 — Create the enterprise VPC fixture (billable: NAT, EIP, endpoints).
# Applies test/enterprise-testbed/enterprise-vpc and leaves its state in that dir.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VPC_DIR="$HERE/enterprise-vpc"
AUTO="${1:-}"

echo "=== 02 — create enterprise VPC ($VPC_DIR) ==="
cd "$VPC_DIR"
terraform init -input=false >/dev/null
terraform plan -input=false -out=tfplan

if [ "$AUTO" != "--yes" ]; then
  read -r -p "Apply this plan? Creates billable resources (NAT, endpoints). [type 'yes']: " ans
  [ "$ans" = "yes" ] || { echo "aborted."; rm -f tfplan; exit 1; }
fi

terraform apply -input=false tfplan
rm -f tfplan

echo ""
echo "VPC created. Outputs:"
terraform output
