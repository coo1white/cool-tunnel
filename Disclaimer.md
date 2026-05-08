# Disclaimer

COOL TUNNEL is a free, open-source macOS client that wraps the upstream
[NaiveProxy](https://github.com/klzgrad/naiveproxy) protocol. It is provided
**as-is**, for educational and research purposes only.

## Intended use

This software is intended for legitimate uses such as:

- Learning how SOCKS / HTTPS proxies and PAC files interact with macOS network
  settings.
- Operating a personal proxy on infrastructure you own or are explicitly
  authorised to use.
- Performing security research, auditing, and academic study.

This software is **not** intended to facilitate any activity that would
violate applicable law in the jurisdiction where it is used.

## Jurisdictional legal risk

This software has the technical capability to circumvent network
restrictions imposed by governments, employers, schools, and ISPs.
**Some jurisdictions criminalise the use of unauthorised
circumvention tools, the operation of unauthorised proxy servers,
or both.** You are solely responsible for understanding and
complying with the laws of any jurisdiction where you download,
build, install, run, distribute, or operate Cool Tunnel — including
laws that may apply when traffic transits a jurisdiction other than
the one in which you are physically located.

The authors and contributors of Cool Tunnel:

- Have **no knowledge** of who downloads, builds, installs, runs,
  or operates this software (no telemetry; see "No data collection"
  below).
- Provide **no legal advice** about the use of this software in
  any jurisdiction. Consult a qualified lawyer in your jurisdiction
  before relying on this software for any purpose where legality
  is uncertain.
- Will **not respond to law-enforcement requests** asking us to
  identify users — we have no records to provide. The repository's
  git history and GitHub's account-level metadata are the only
  records that exist, and they're already public.

## User responsibility

By downloading, building, installing, or running COOL TUNNEL you acknowledge
and agree that:

1. **Compliance with local law is solely your responsibility.** The authors
   neither endorse nor encourage any illegal activity, including but not
   limited to unauthorised circumvention of network restrictions imposed by
   law, your employer, your school, or any service whose terms of use you
   have accepted.
2. **You will not use this software to violate the terms of service of any
   network you do not own or operate.**
3. **You will configure the upstream server (the `naive` endpoint) yourself.**
   COOL TUNNEL ships no preconfigured server, no embedded credentials, and no
   directory of public servers. The application cannot connect anywhere until
   you provide your own server address and credentials.
4. **You assume all risk** arising from running this software on your own
   hardware or any hardware you have permission to use.

## No warranty

This software is distributed under the **Apache License, Version 2.0**
(see [LICENSE](./LICENSE)). It is provided **without any warranty** —
express or implied — including without limitation the warranties of
merchantability, fitness for a particular purpose, and non-infringement.

## No liability

In no event shall the authors, contributors, or copyright holders be liable
for any claim, damages, or other liability — whether in an action of contract,
tort, or otherwise — arising from, out of, or in connection with the
software or the use or other dealings in the software.

## No data collection

COOL TUNNEL does not collect, transmit, or analyse any user data. There is
no telemetry, no analytics, and no remote configuration. Credentials are
stored on the user's device in
`~/Library/Application Support/COOL-TUNNEL/credentials.json` (POSIX mode
0600, parent directory mode 0700) — no Keychain entries, no `UserDefaults`
password storage. The application does not contact any remote service
except the NaiveProxy server you configure yourself, plus
`api.github.com` / `objects.githubusercontent.com` when you click the
in-app Update buttons in Settings.

## Bundled components

COOL TUNNEL bundles a precompiled `naive` Mach-O binary built from
[klzgrad/naiveproxy](https://github.com/klzgrad/naiveproxy), which is
distributed under the BSD-3-Clause license. Users redistributing COOL
TUNNEL must comply with that license in addition to Apache-2.0. The
[NOTICE](./NOTICE) file at the repository root lists every bundled
component and its licence — keep it intact in any redistribution.

## Reporting security issues

If you discover a security vulnerability in COOL TUNNEL, please report it
privately via a [GitHub Security Advisory](https://github.com/coo1white/cool-tunnel/security/advisories/new)
rather than as a public issue.
