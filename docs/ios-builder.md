# Blind iOS builder

This repository contains a generic GitHub Actions executor for private Apple app repositories. The public event carries one opaque job token. Private control data resolves that token into the source commit, Xcode targets, signing repository, and TestFlight settings.

The public workflow entry point is `.github/workflows/testflight.yml`.

The executor runs on GitHub's [`xcode-27` arm64 runner image](https://github.blog/changelog/2026-07-16-xcode-27-runner-image-now-in-public-preview/). It performs four public steps:

1. Prepare the private job and source checkout.
2. Build signed archives and IPAs with Fastlane Match.
3. Upload each IPA to App Store Connect and distribute it to configured external groups.
4. Remove private material from the runner.

Fastlane output, Xcode output, dependency output, and private source paths stay in `$RUNNER_TEMP`. Public step output contains generic completion messages.

The public workflow uses one `ios-build-queue` concurrency group. This serializes build-number allocation across all queued apps.

## Required private control repository

Create a private repository with a `jobs/` directory. Each job is a JSON file named with its opaque job token:

```text
jobs/<opaque-job-token>.json
```

The private app trigger creates this file before dispatching the public event. A job file has this shape:

```json
{
  "source": {
    "repository": "owner/private-app",
    "sha": "full-commit-sha"
  },
  "project": {
    "kind": "project",
    "path": "App.xcodeproj",
    "targets": [
      {
        "id": "mobile",
        "scheme": "App",
        "platform": "ios",
        "sdk": "iphoneos",
        "bundle_ids": ["com.example.app"],
        "testflight_groups": ["External"]
      }
    ]
  },
  "build": {
    "configuration": "Release"
  },
  "signing": {
    "git_url": "https://github.com/owner/private-signing.git",
    "branch": "main",
    "type": "appstore"
  },
  "testflight": {
    "distribute_external": true,
    "notify_external_testers": true,
    "submit_beta_review": true,
    "uses_non_exempt_encryption": false,
    "wait_processing_timeout_duration": 3600
  }
}
```

The control repository is private and should expire completed job files through its own retention workflow. The public executor receives read access to the control, source, and signing repositories through the `CI_GITHUB_PAT` secret.

## PAT and secrets

Store a fine-grained personal access token as `CI_GITHUB_PAT` in the public builder and each private app repository. Grant the public builder read access to the control, source, and signing repositories. Grant each private app repository contents write access to the control and builder repositories.

Add these secrets to the public builder repository:

```text
CI_GITHUB_PAT
CI_CONTROL_REPO
CI_CONTROL_BRANCH              optional; defaults to main
CI_CONTROL_JOBS_PATH           optional; defaults to jobs
MATCH_PASSWORD
ASC_KEY_ID
ASC_ISSUER_ID
ASC_PRIVATE_KEY
ASC_PRIVATE_KEY_BASE64         optional; set to true for a base64 key
```

The App Store Connect key needs permission to upload builds and manage TestFlight distribution. The signing repository uses Fastlane Match in read-only mode during the public build.

Each private app repository also stores `CI_BUILDER_REPO` as the `owner/repository` name of this public builder. Its `CI_GITHUB_PAT` needs contents write access to the control repository and dispatch access to the builder repository.

## Private app trigger

Each private app stores its target metadata in `.ci/ios-build.json`. Its private workflow should:

1. Generate a fresh UUID.
2. Add the current repository and commit SHA to the JSON configuration.
3. Commit `jobs/<uuid>.json` to the private control repository.
4. POST a `repository_dispatch` event to this public repository with `{ "job": "<uuid>" }`.

The public event carries the opaque token. The private control entry carries all app-specific values.

## Local checks

Run these checks from the repository root:

```bash
bash -n scripts/ios-builder.sh
ruby -c fastlane/Fastfile
```

The release path requires GitHub secrets, the private control repository, the signing repository, and App Store Connect access.
