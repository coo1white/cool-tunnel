# Disclaimer

COOL TUNNEL is a free, open-source macOS client that wraps the upstream [sing-box](https://github.com/SagerNet/sing-box) data plane (VLESS + Reality). Provided **as-is**, for educational and research purposes only.

## Intended use

Legitimate uses such as:

- Learning how SOCKS / HTTPS proxies and PAC files interact with macOS network settings.
- Operating a personal proxy on infrastructure you own or are explicitly authorised to use.
- Performing security research, auditing, and academic study.

This software is **not** intended to facilitate any activity that would violate applicable law in the jurisdiction where it is used.

## Jurisdictional legal risk

This software has the technical capability to circumvent network restrictions imposed by governments, employers, schools, and ISPs. **Some jurisdictions criminalise the use of unauthorised circumvention tools, the operation of unauthorised proxy servers, or both.** You are solely responsible for understanding and complying with the laws of any jurisdiction where you download, build, install, run, distribute, or operate Cool Tunnel — including laws that may apply when traffic transits a jurisdiction other than the one in which you are physically located.

The authors and contributors of Cool Tunnel:

- Have **no knowledge** of who downloads, builds, installs, runs, or operates this software (no telemetry; see "No data collection" below).
- Provide **no legal advice** about the use of this software in any jurisdiction. Consult a qualified lawyer in your jurisdiction before relying on this software for any purpose where legality is uncertain.
- Will **not respond to law-enforcement requests** asking us to identify users — we have no records to provide. The repository's git history and GitHub's account-level metadata are the only records that exist, and they're already public.

## User responsibility

By downloading, building, installing, or running COOL TUNNEL you acknowledge and agree that:

1. **Compliance with local law is solely your responsibility.** The authors neither endorse nor encourage any illegal activity, including but not limited to unauthorised circumvention of network restrictions imposed by law, your employer, your school, or any service whose terms of use you have accepted.
2. **You will not use this software to violate the terms of service of any network you do not own or operate.**
3. **You will configure the upstream server (the sing-box endpoint) yourself.** COOL TUNNEL ships no preconfigured server, no embedded credentials, and no directory of public servers. The application cannot connect anywhere until you provide your own server address and credentials.
4. **You assume all risk** arising from running this software on your own hardware or any hardware you have permission to use.

## No warranty

Distributed under the **GNU Affero General Public License, Version 3** (see [LICENSE](./LICENSE)), copyright © 2026 coolwhite LLC. Provided **without any warranty** — express or implied — including without limitation the warranties of merchantability, fitness for a particular purpose, and non-infringement (AGPL §§ 15–16).

Two AGPL clauses worth highlighting:

- **Source-availability on network use** (AGPL § 13). If you modify Cool Tunnel and run a modified version as a network service that other users interact with, you must offer those users access to the corresponding source under the same AGPL terms. For a desktop GUI client run on your own machine for your own use this clause has no surface to attach to; it matters only when running modified copies as a service.
- **No warranty / no liability** (AGPL §§ 15–16). The software is provided "AS IS, AS AVAILABLE, WITHOUT ANY WARRANTY". The contributors are not liable for any damages, claims, or legal consequences arising from your deployment, your network's activities, or any third party's use of this software.

## No liability

In no event shall the authors, contributors, or copyright holders be liable for any claim, damages, or other liability — whether in an action of contract, tort, or otherwise — arising from, out of, or in connection with the software or the use or other dealings in the software.

## No data collection

COOL TUNNEL does not collect, transmit, or analyse any user data. No telemetry, no analytics, no remote configuration. Credentials are stored on the user's device in `~/Library/Application Support/COOL-TUNNEL/credentials.json` (POSIX mode 0600, parent directory mode 0700) — no Keychain entries, no `UserDefaults` password storage. The application does not contact any remote service except the sing-box server you configure yourself, plus `api.github.com` / `objects.githubusercontent.com` when you click the in-app Update buttons in Settings.

## Bundled components

COOL TUNNEL bundles a precompiled `sing-box` Mach-O binary built from [SagerNet/sing-box](https://github.com/SagerNet/sing-box), distributed under GPL-3.0. Users redistributing COOL TUNNEL must comply with that license in addition to AGPL-3.0. The [NOTICE](./NOTICE) file lists every bundled component and its licence — keep it intact in any redistribution.

## Reporting security issues

Report security vulnerabilities privately via a [GitHub Security Advisory](https://github.com/coo1white/cool-tunnel/security/advisories/new) rather than as a public issue.
