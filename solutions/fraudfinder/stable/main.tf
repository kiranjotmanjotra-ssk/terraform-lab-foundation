/*
  Get GCP project number (int)
*/

data "google_project" "project" {}

/*
  Enable Required APIs
*/
variable "gcp_service_list" {
  description = "The list of apis necessary for the project"
  type        = list(string)
  default = [
    "compute.googleapis.com",
    "containerregistry.googleapis.com",
    "aiplatform.googleapis.com",
    "notebooks.googleapis.com",
    "cloudresourcemanager.googleapis.com",
    "pubsub.googleapis.com",
    "cloudbuild.googleapis.com",
    "dataflow.googleapis.com",
    "bigquery.googleapis.com",
    "run.googleapis.com",
    "artifactregistry.googleapis.com",
    "iam.googleapis.com",
  ]
}

resource "google_project_service" "gcp_services" {
  for_each = toset(var.gcp_service_list)
  project  = var.gcp_project_id
  service  = each.key
}


/*
  Random Generator
*/

resource "random_string" "rand" {
  length  = 5
  special = false
  lower   = true
  upper   = false
}

locals {
  ID                            = random_string.rand.result
  NOTEBOOK_LOG                  = "/tmp/notebook_config.log"
  compute_service_account_email = "${data.google_project.project.number}-compute@developer.gserviceaccount.com"
  cloud_build_service_account_email = "${data.google_project.project.number}@cloudbuild.gserviceaccount.com"
}

/*
  Create Pub/Sub subscriptions
*/

resource "google_pubsub_subscription" "ff-tx-subscription" {
  project = var.gcp_project_id
  name    = "ff-tx-sub"
  topic   = "projects/cymbal-fraudfinder/topics/ff-tx"
}

resource "google_pubsub_subscription" "ff-tx-for-feat-eng-subscription" {
  project = var.gcp_project_id
  name    = "ff-tx-for-feat-eng-sub"
  topic   = "projects/cymbal-fraudfinder/topics/ff-tx"
}

resource "google_pubsub_subscription" "ff-txlabels-subscription" {
  project = var.gcp_project_id
  name    = "ff-txlabels-sub"
  topic   = "projects/cymbal-fraudfinder/topics/ff-txlabels"
}

/*
  Assign Appropriate IAM Permissions to the compute SA
*/


variable "compute_service_account_project_iam_list" {
  description = "Roles needed for compute SA"
  type        = list(string)
  default = [
    "roles/storage.admin",
    "roles/run.admin",
    "roles/bigquery.admin",
    "roles/aiplatform.admin",
    "roles/resourcemanager.projectIamAdmin",
    "roles/cloudbuild.builds.editor",
    "roles/cloudbuild.integrations.editor",
    "roles/artifactregistry.admin",
    "roles/cloudfunctions.admin",
    "roles/dataflow.admin",
    "roles/notebooks.admin",
    "roles/pubsub.admin",
    "roles/iam.serviceAccountAdmin",
  ]
}

resource "google_project_iam_member" "servacct-compute-add-permissions" {
  for_each = toset(var.compute_service_account_project_iam_list)
  project  = var.gcp_project_id
  role     = each.key
  member   = "serviceAccount:${local.compute_service_account_email}"
}

/*
  Assign Appropriate IAM Permissions to the Cloud Build SA
*/

variable "cloud_build_service_account_project_iam_list" {
  description = "Roles needed for compute SA"
  type        = list(string)
  default = [
    "roles/run.admin",
    "roles/aiplatform.admin",
    "roles/cloudbuild.builds.editor",
    "roles/cloudbuild.integrations.editor",
    "roles/iam.serviceAccountAdmin",
  ]
}

resource "google_project_iam_member" "servacct-cloud-build-add-permissions" {
  for_each = toset(var.cloud_build_service_account_project_iam_list)
  project  = var.gcp_project_id
  role     = each.key
  member   = "serviceAccount:${local.cloud_build_service_account_email}"
}


/*
  Create GCP Storage Bucket
  Set storage admin on bucket to SA and Lab user
*/
resource "google_storage_bucket" "fraudfinder_bucket" {
  name          = "${var.gcp_project_id}-fraudfinder"
  location      = var.gcp_region
  force_destroy = true
}

resource "google_storage_bucket_iam_binding" "fraudfinder_bucket_iam_binding" {
  bucket = google_storage_bucket.fraudfinder_bucket.name
  role   = "roles/storage.admin"
  members = [
    "user:${var.gcp_user_id}",
    "serviceAccount:${local.compute_service_account_email}"
  ]
}

resource "google_storage_bucket" "lab_config_bucket" {
  name          = "${var.gcp_project_id}-labconfig-bucket"
  location      = var.gcp_region
  force_destroy = true
}

resource "google_storage_bucket_iam_binding" "lab_config_bucket_iam_binding" {
  bucket = google_storage_bucket.lab_config_bucket.name
  role   = "roles/storage.admin"
  members = [
    "user:${var.gcp_user_id}",
    "serviceAccount:${local.compute_service_account_email}"
  ]
}

/*
  Create config scripts & upload to buckets
*/

resource "local_file" "notebook_config" {

  content = <<EOF
echo "Current user: `id`" >> ${local.NOTEBOOK_LOG} 2>&1
echo "Creating pub/sub subscriptions" >> ${local.NOTEBOOK_LOG} 2>&1
gcloud pubsub subscriptions create "ff-tx-sub" --topic="ff-tx" --topic-project="cymbal-fraudfinder" >> ${local.NOTEBOOK_LOG} 2>&1
gcloud pubsub subscriptions create "ff-tx-for-feat-eng-sub" --topic="ff-tx" --topic-project="cymbal-fraudfinder"
gcloud pubsub subscriptions create "ff-txlabels-sub" --topic="ff-txlabels" --topic-project="cymbal-fraudfinder" >> ${local.NOTEBOOK_LOG} 2>&1
echo "Changing dir to /home/jupyter" >> ${local.NOTEBOOK_LOG} 2>&1
cd /home/jupyter
echo "Cloning fraudfinder from github" >> ${local.NOTEBOOK_LOG} 2>&1
su - jupyter -c "git clone https://github.com/GoogleCloudPlatform/fraudfinder.git" >> ${local.NOTEBOOK_LOG} 2>&1
echo "Current user: `id`" >> ${local.NOTEBOOK_LOG} 2>&1
echo "Installing python packages" >> ${local.NOTEBOOK_LOG} 2&1
su - jupyter -c "pip install --upgrade --no-warn-conflicts --no-warn-script-location --user \
    google-cloud-pubsub==2.13.6 \
    google-api-core==2.8.2 \
    google-apitools==0.5.32 \
    plotly==5.10.0 \
    itables==1.2.0 \
    xgboost==1.6.2 \
    apache_beam==2.40.0 \
    plotly==5.10.0 \
    google-cloud-pipeline-components \
    kfp" >> ${local.NOTEBOOK_LOG} 2>&1

echo "Executing biqquery data copy script" >> ${local.NOTEBOOK_LOG} 2>&1
su - jupyter -c "python /home/jupyter/fraudfinder/scripts/copy_bigquery_data.py ${google_storage_bucket.fraudfinder_bucket.name}" >> ${local.NOTEBOOK_LOG} 2>&1

EOF

  filename = "notebook_config.sh"
}

resource "google_storage_bucket_object" "notebook_config_script" {
  name   = "notebook_config.sh"
  source = "notebook_config.sh"
  bucket = google_storage_bucket.lab_config_bucket.name
  depends_on = [
    google_storage_bucket.lab_config_bucket,
    local_file.notebook_config
  ]
}

resource "local_file" "config_data" {

  content = <<EOF
BUCKET_NAME          = "${google_storage_bucket.fraudfinder_bucket.name}"
PROJECT              = "${var.gcp_project_id}"
REGION               = "${var.gcp_region}"
ID                   = "${local.ID}"
FEATURESTORE_ID      = "fraudfinder_${local.ID}"
MODEL_NAME           = "fraudfinder_logreg_model"
ENDPOINT_NAME        = "fraudfinder_logreg_endpoint"
TRAINING_DS_SIZE     = "1000"
EOF

  filename = "notebook_env.py"
}

resource "google_storage_bucket_object" "notebook_env_file" {
  name   = "config/notebook_env.py"
  source = "notebook_env.py"
  bucket = google_storage_bucket.fraudfinder_bucket.name
  depends_on = [
    google_storage_bucket.fraudfinder_bucket,
    local_file.config_data
  ]
}

/*
  Create Vertex AI Notebook
*/

resource "google_notebooks_instance" "ff-notebook" {
  name               = "ff-jupyterlab"
  project            = var.gcp_project_id
  location           = var.gcp_zone
  machine_type       = "n1-standard-4" // n1-standard-1 $112.91 monthly estimate
  install_gpu_driver = false
  service_account    = "${local.compute_service_account_email}"
  vm_image { // https://cloud.google.com/vertex-ai/docs/workbench/user-managed/images
    project      = "deeplearning-platform-release"
    image_family = "common-cpu-notebooks"
  }

  post_startup_script = "gs://${var.gcp_project_id}-labconfig-bucket/notebook_config.sh"
  
  depends_on = [google_project_service.gcp_services, google_storage_bucket_object.notebook_config_script]
}

# resource "google_artifact_registry_repository" "mlops-repo" {
#   location      = "us-central1"
#   repository_id = "mlops-repository"
#   description   = "MLOps Docker Repository"
#   format        = "DOCKER"
# }

/*
  Create PubSub topics for transactions
*/

# resource "google_pubsub_subscription" "ff_tx-sub" {
#   name    = "ff-tx-sub"
#   topic   = "ff-tx"
# }

# resource "google_pubsub_subscription" "ff_txlabels_sub" {
#   project = "cymbal-fraudfinder"
#   name    = "ff-txlabels-sub"
#   topic   = "ff-txlabels"
# }
