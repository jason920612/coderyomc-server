# coderyoMC API doc-site

Lightweight publishable scaffold for the **coderyoMC API** documentation, in the
spirit of [jd.papermc.io](https://jd.papermc.io/).

## What this is

The browsable HTML API reference is the **Javadoc** generated from the
`coderyo-api` subproject (`com.coderyo` public API surface), produced by the
standard JDK 25 Javadoc tool via the Gradle `:coderyo-api:javadoc` task.

`docs-site/` holds only the publishing wrapper:

- `index.html.template` &mdash; a branded **"coderyoMC API"** landing page. The
  token `@API_VERSION@` is substituted with the `apiVersion` Gradle property
  (currently `26.2`) at publish time, so the page is always versioned.

## How the published site is assembled

The CI workflow (`.github/workflows/docs.yml`) builds the site into a single
artifact directory laid out as:

```
_site/
├── index.html            # landing page (from index.html.template, version-substituted)
└── apidocs/              # the generated coderyo-api Javadoc (index.html + package pages)
```

`index.html` links into `apidocs/index.html`. This mirrors the PaperMC docs
layout (a versioned landing page in front of the generated Javadoc).

## Regenerating locally

```bash
./gradlew :coderyo-api:javadoc
# output: coderyo-api/build/docs/javadoc/index.html
```

The tooling is intentionally driven by the Gradle Javadoc task (not a hand-built
file list), so it regenerates cleanly as the API grows &mdash; region API,
plugin-compat hooks, and the `ComputeBackend` SPI will all appear automatically.
