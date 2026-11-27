#!/usr/bin/env python3
"""
Verify Image Exists in ECR

Checks that a specific image tag exists in the target ECR repository.
Used by the prod pipeline before deployment to ensure the promoted
image has been replicated from non-prod.

Exits 0 if image exists, exits 1 with clear error if not found.
"""

import argparse
import sys

import boto3


def verify_image(repo_name: str, image_tag: str, region: str) -> bool:
    """Check if an image tag exists in the ECR repository."""
    client = boto3.client("ecr", region_name=region)
    try:
        response = client.describe_images(
            repositoryName=repo_name,
            imageIds=[{"imageTag": image_tag}],
        )
        images = response.get("imageDetails", [])
        return len(images) > 0
    except client.exceptions.ImageNotFoundException:
        return False
    except client.exceptions.RepositoryNotFoundException:
        print(f"ERROR: Repository '{repo_name}' not found in {region}")
        return False
    except Exception as e:
        print(f"ERROR: {e}")
        return False


def main():
    parser = argparse.ArgumentParser(description="Verify image exists in ECR")
    parser.add_argument("--repo", required=True, help="ECR repository name")
    parser.add_argument("--tag", required=True, help="Image tag to verify")
    parser.add_argument("--region", default="us-east-1", help="AWS region")
    args = parser.parse_args()

    print(f"Verifying image: {args.repo}:{args.tag} in {args.region}")

    if verify_image(args.repo, args.tag, args.region):
        print(f"✓ Image {args.repo}:{args.tag} exists")
        sys.exit(0)
    else:
        print(f"✗ Image {args.repo}:{args.tag} NOT FOUND")
        print(f"  The image has not been promoted/replicated to this account.")
        print(f"  Ensure the image passed QA graduation and ECR replication completed.")
        sys.exit(1)


if __name__ == "__main__":
    main()
