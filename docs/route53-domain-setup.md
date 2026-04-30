# Route53 Domain and Hosted Zone Guide

This guide is for a novice AWS administrator who is not already familiar with Route53.

Use it during the initial deployment when the README tells you to register a domain and decide how the hosted zone will be handled.

## What You Need to Decide

For this repository, you need two things:

1. A domain name that users will call, for example `llm.example.com`
2. A Route53 public hosted zone that Terraform can use for ACM DNS validation and the public API DNS record

Important:

- the hosted zone is usually for the parent domain, such as `example.com`
- the application hostname can be a subdomain, such as `llm.example.com`
- you do not manually create the final `llm.example.com` record for this repo; Terraform creates it and points it at the public ALB

There are two common paths:

- register a new domain in Route53 Domains
- use a domain that is already registered somewhere else and create or reuse a Route53 hosted zone

## Key Route53 Concepts

- **Registered domain**: the domain name you own, such as `example.com`
- **Registrar**: the company or service where the domain is registered
- **Hosted zone**: the Route53 DNS container that stores DNS records for a domain
- **Name servers**: the DNS servers that the internet uses for your domain

Why this matters for this repo:

- Terraform needs a Route53 hosted zone to create ACM DNS validation records
- the public API endpoint will live as a record inside that hosted zone
- if the domain is registered outside AWS, you usually need to update the registrar to use the Route53 name servers

Example:

- hosted zone: `example.com`
- application hostname: `llm.example.com`
- Terraform creates the `llm.example.com` alias record in the `example.com` hosted zone

## Option 1: Register a New Domain in Route53 Domains

This is the easiest path for a first-time AWS operator.

Important AWS behavior:

- when you register a domain with Route53, AWS automatically creates a hosted zone for that domain
- that hosted zone has Route53 name servers assigned automatically

High-level steps:

1. Sign in to the AWS console.
2. Open the Route53 console.
3. In the navigation pane, open `Domains`, then `Registered domains`.
4. Choose `Register domains`.
5. Search for the domain you want.
6. If it is available, continue through the checkout flow.
7. Enter registrant/contact details.
8. Complete payment and registration.
9. Wait for registration to finish.

Success signal:

- the domain appears under `Registered domains`
- a matching hosted zone appears under `Hosted zones`

What to record for this repository:

- your domain name
- the hosted zone ID created by Route53

How to find the hosted zone ID:

1. In Route53, choose `Hosted zones`
2. Open the hosted zone for your domain
3. Copy the hosted zone ID shown in the zone details

Recommended Terraform usage after this:

- set `create_route53_zone = false`
- set `route53_zone_id = "Z..."`

Why not `create_route53_zone = true` here:

- because Route53 Domains already created the hosted zone for you
- creating a second hosted zone for the same domain would create confusion and likely break DNS

## Option 2: Use a Domain Registered Outside AWS

Use this if the domain is already owned at another registrar such as Cloudflare Registrar, Namecheap, GoDaddy, or similar.

High-level steps:

1. Confirm you control the existing domain.
2. In AWS Route53, open `Hosted zones`.
3. Create a new **public hosted zone** for the parent domain you want to use.
4. Copy the four Route53 name servers from the new hosted zone.
5. Log in to the external registrar.
6. Replace the domain’s current name servers with the Route53 name servers.
7. Wait for DNS changes to propagate.

Success signal:

- the domain is using the Route53 name servers
- the hosted zone exists in Route53

Recommended Terraform usage after this:

- set `create_route53_zone = false`
- set `route53_zone_id = "Z..."`

## Option 3: Let Terraform Create the Hosted Zone

This is supported, but it is best when:

- you already own the domain
- you are comfortable updating registrar name servers manually after Terraform runs

What happens:

- Terraform creates the Route53 public hosted zone
- you must then update the registrar to use that zone’s name servers

Use this when:

- the domain is external to AWS and you want Terraform to create the hosted zone object itself

Recommended Terraform usage:

- set `create_route53_zone = true`
- leave `route53_zone_id = null`

Important follow-up:

- after `terraform apply`, copy the hosted zone name servers from Route53 and set them at the registrar

## Which Option Is Best?

For a novice AWS admin:

- best: register the domain in Route53 Domains
- second best: use an external registrar but create or reuse one Route53 hosted zone manually
- most advanced: let Terraform create the hosted zone and then update registrar name servers yourself

## How This Connects to ACM

This repository uses ACM public certificates with DNS validation.

That means:

- ACM gives Terraform DNS validation records
- Terraform writes those records into the Route53 hosted zone
- ACM only validates successfully if the hosted zone is authoritative for the domain

If ACM validation hangs, the most common causes are:

- wrong hosted zone ID
- wrong registrar name servers
- duplicated hosted zones for the same domain
- DNS propagation still in progress

## Recommended Inputs for This Repo

If Route53 already has the correct hosted zone:

```hcl
domain_name         = "llm.example.com"
create_route53_zone = false
route53_zone_id     = "Z1234567890EXAMPLE"
```

In this example:

- the hosted zone might be `example.com`
- `domain_name` is still `llm.example.com`
- Terraform creates the final `llm.example.com` record in the `example.com` zone

If Terraform should create the hosted zone:

```hcl
domain_name         = "llm.example.com"
create_route53_zone = true
route53_zone_id     = null
```

## Common Mistakes to Avoid

- creating a second hosted zone for a domain that already has a working Route53 hosted zone
- setting `create_route53_zone = true` when Route53 Domains already created one for you
- forgetting to update external registrar name servers to Route53
- using the wrong hosted zone ID for the chosen domain
- expecting a separate hosted zone for `llm.example.com` when the real hosted zone is `example.com`
- manually creating the final app host record even though Terraform manages it
- expecting ACM validation to work before DNS delegation is correct

## How to Verify You Are Ready

You are ready for the next Terraform step when:

- you know the exact `domain_name` to use
- you know whether you are reusing an existing hosted zone or creating one
- if reusing, you know the correct `route53_zone_id`
- if the registrar is external, its name servers point at Route53 or you have a concrete plan to update them

## AWS References

Official AWS docs used for this guide:

- Registering a new domain with Route53: https://docs.aws.amazon.com/Route53/latest/DeveloperGuide/domain-register.html
- Creating a public hosted zone: https://docs.aws.amazon.com/Route53/latest/DeveloperGuide/CreatingHostedZone.html
- Route53 domain registration overview: https://docs.aws.amazon.com/Route53/latest/DeveloperGuide/welcome-domain-registration.html
