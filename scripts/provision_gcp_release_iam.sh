#!/bin/zsh
# Apply the least-privilege IAM bindings for Lima's already-created GCP release
# resources. Run only as a GCP IAM administrator after reviewing the project,
# repository IDs, buckets, service accounts, and Secret Manager resource names.
set -euo pipefail

PROJECT_ID="${1:-lima-build-prod}"
PROJECT_NUMBER="${2:-940267100054}"
REPOSITORY_ID="${LIMA_GITHUB_REPOSITORY_ID:-1342815274}"
POOL_ID="${LIMA_GCP_WIF_POOL_ID:-github}"
CI_SERVICE_ACCOUNT="lima-ci@$PROJECT_ID.iam.gserviceaccount.com"
RELEASE_SERVICE_ACCOUNT="lima-release@$PROJECT_ID.iam.gserviceaccount.com"
ASSET_BUCKET="${LIMA_BUILD_ASSET_BUCKET:-lima-build-assets-$PROJECT_NUMBER}"
ARCHIVE_BUCKET="${LIMA_RELEASE_ARCHIVE_BUCKET:-lima-release-archive-$PROJECT_NUMBER}"
WIF_MEMBER="principalSet://iam.googleapis.com/projects/$PROJECT_NUMBER/locations/global/workloadIdentityPools/$POOL_ID/attribute.repository_id/$REPOSITORY_ID"

usage() {
    print 'Usage: provision_gcp_release_iam.sh [project-id] [project-number]'
}
[[ "${1:-}" != --help && "${1:-}" != -h ]] || { usage; exit 0; }
[[ "$PROJECT_ID" =~ '^[a-z][a-z0-9-]{4,28}[a-z0-9]$' ]] || { print -u2 'Invalid project ID.'; exit 2; }
[[ "$PROJECT_NUMBER" =~ '^[0-9]+$' && "$REPOSITORY_ID" =~ '^[0-9]+$' ]] || { print -u2 'Project and repository IDs must be numeric.'; exit 2; }

for service_account in "$CI_SERVICE_ACCOUNT" "$RELEASE_SERVICE_ACCOUNT"; do
    gcloud iam service-accounts add-iam-policy-binding "$service_account" \
        --project "$PROJECT_ID" \
        --role roles/iam.workloadIdentityUser \
        --member "$WIF_MEMBER"
done

gcloud storage buckets add-iam-policy-binding "gs://$ASSET_BUCKET" \
    --member "serviceAccount:$CI_SERVICE_ACCOUNT" \
    --role roles/storage.objectViewer
gcloud storage buckets add-iam-policy-binding "gs://$ASSET_BUCKET" \
    --member "serviceAccount:$RELEASE_SERVICE_ACCOUNT" \
    --role roles/storage.objectViewer
for role in roles/storage.objectViewer roles/storage.objectCreator; do
    gcloud storage buckets add-iam-policy-binding "gs://$ARCHIVE_BUCKET" \
        --member "serviceAccount:$RELEASE_SERVICE_ACCOUNT" \
        --role "$role"
done

for secret in lima-signing-p12 lima-signing-p12-password lima-sparkle-private-key; do
    gcloud secrets add-iam-policy-binding "$secret" \
        --project "$PROJECT_ID" \
        --member "serviceAccount:$RELEASE_SERVICE_ACCOUNT" \
        --role roles/secretmanager.secretAccessor
done

print "Applied Lima CI/release WIF and least-privilege resource bindings."
