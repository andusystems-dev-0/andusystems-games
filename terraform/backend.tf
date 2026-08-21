# TF state in S3 (estate convention: andusystems-tfstate, per-repo key). App data/backups live in R2.
terraform {
  backend "s3" {
    bucket = "andusystems-tfstate"
    key    = "games/layer-1-cluster/terraform.tfstate"
    region = "us-east-1"
    # credentials via env (AWS_* / the shipyard profile) — never committed. See docs/runbook.md.
  }
}
