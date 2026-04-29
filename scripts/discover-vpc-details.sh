#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: discover-vpc-details.sh --vpc-id VPC_ID [--region REGION] [--profile PROFILE]

Prints JSON describing a VPC, its subnets, route tables, and an inferred
public/private classification based on subnet map-public-ip settings and
routes to an Internet Gateway.
EOF
}

VPC_ID=""
REGION=""
PROFILE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --vpc-id) VPC_ID="$2"; shift 2 ;;
    --region) REGION="$2"; shift 2 ;;
    --profile) PROFILE="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1"; usage; exit 1 ;;
  esac
done

if [[ -z "${VPC_ID}" ]]; then
  usage
  exit 1
fi

for cmd in aws jq; do
  command -v "${cmd}" >/dev/null 2>&1 || {
    echo "Missing required command: ${cmd}" >&2
    exit 1
  }
done

AWS_ARGS=()
if [[ -n "${PROFILE}" ]]; then
  AWS_ARGS+=(--profile "${PROFILE}")
fi
if [[ -n "${REGION}" ]]; then
  AWS_ARGS+=(--region "${REGION}")
fi

VPC_JSON="$(aws "${AWS_ARGS[@]}" ec2 describe-vpcs --vpc-ids "${VPC_ID}")"
SUBNETS_JSON="$(aws "${AWS_ARGS[@]}" ec2 describe-subnets --filters "Name=vpc-id,Values=${VPC_ID}")"
ROUTE_TABLES_JSON="$(aws "${AWS_ARGS[@]}" ec2 describe-route-tables --filters "Name=vpc-id,Values=${VPC_ID}")"

jq -n \
  --argjson vpc "${VPC_JSON}" \
  --argjson subnets "${SUBNETS_JSON}" \
  --argjson route_tables "${ROUTE_TABLES_JSON}" '
  def subnet_name($id):
    (($subnets.Subnets[] | select(.SubnetId == $id) | .Tags // [])
      | map(select(.Key == "Name") | .Value)
      | .[0]) // "";

  def route_table_for_subnet($subnet_id):
    (
      $route_tables.RouteTables
      | map(select(any(.Associations[]?; .SubnetId == $subnet_id)))
      | .[0]
    ) // (
      $route_tables.RouteTables
      | map(select(any(.Associations[]?; .Main == true)))
      | .[0]
    );

  def has_igw_route($rt):
    any($rt.Routes[]?; (.GatewayId // "") | startswith("igw-"));

  {
    vpc: {
      id: ($vpc.Vpcs[0].VpcId),
      cidr_block: ($vpc.Vpcs[0].CidrBlock),
      tags: ($vpc.Vpcs[0].Tags // [])
    },
    route_tables: (
      $route_tables.RouteTables
      | map({
          route_table_id: .RouteTableId,
          associations: (.Associations // []),
          routes: (.Routes // [])
        })
    ),
    subnets: (
      $subnets.Subnets
      | map(
          . as $subnet
          | route_table_for_subnet(.SubnetId) as $rt
          | {
              subnet_id: .SubnetId,
              availability_zone: .AvailabilityZone,
              cidr_block: .CidrBlock,
              name: subnet_name(.SubnetId),
              map_public_ip_on_launch: .MapPublicIpOnLaunch,
              route_table_id: ($rt.RouteTableId // null),
              inferred_type: (
                if (.MapPublicIpOnLaunch == true) or has_igw_route($rt) then
                  "public"
                else
                  "private"
                end
              )
            }
        )
    ),
    summary: {
      public_subnet_ids: (
        $subnets.Subnets
        | map(
            . as $subnet
            | route_table_for_subnet(.SubnetId) as $rt
            | select((.MapPublicIpOnLaunch == true) or has_igw_route($rt))
            | .SubnetId
          )
      ),
      private_subnet_ids: (
        $subnets.Subnets
        | map(
            . as $subnet
            | route_table_for_subnet(.SubnetId) as $rt
            | select(((.MapPublicIpOnLaunch == true) or has_igw_route($rt)) | not)
            | .SubnetId
          )
      ),
      route_table_ids: (
        $route_tables.RouteTables | map(.RouteTableId) | unique
      )
    }
  }'
