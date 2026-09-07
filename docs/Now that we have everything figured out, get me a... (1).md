# **Enterprise System Architecture Document: WAEC Automated Verification & Direct Retrieval Platform**

## **Executive Summary & System Overview**

This document details the enterprise architecture, cryptography, frontend user experience, and operational infrastructure for the **WAEC Automated Verification & Direct Retrieval Platform**.  
The platform serves West African candidates (Ghana and Nigeria) by providing instant, automated retrieval of official WAEC examination results. Operating on an **On-Demand Direct Retrieval Architecture**, the system processes candidate verification and payment in real time without storing sensitive student performance data on persistent backend databases.

                                    \[ CLIENT LAYER \]
                        \+------------------------------------+
                        |  Flutter Mobile Application        |
                        |  \- Native ARM Binary (Obfuscated)  |
                        |  \- TLS 1.3 / Certificate Pinning   |
                        |  \- In-Memory State (Riverpod)      |
                        \+-----------------+------------------+
                                          |
                                          | TLS 1.3 / Encrypted REST
                                          v
                                \[ EDGE GATEWAY LAYER \]
                        \+------------------------------------+
                        | NGINX / Kong API Gateway & LB      |
                        | \- SSL Termination (TLS 1.3)        |
                        | \- Rate Limiting & DDoS Defense     |
                        | \- Path Routing & CORS Control      |
                        \+-----------------+------------------+
                                          |
                                          | Internal mTLS (Subnet 10.0.1.0/24)
                                          v
                              \[ RUST MICROSERVICES WORKSPACE \]

\+---------------------------------------------------------------------------------+  
 | |  
 | \+---------------------+ \+---------------------+ \+-----------------------+ |  
 | | Auth Service | | Payment Service | | Distributor Service | |  
 | | \- Argon2id Password| | \- Paystack Engine | | \- JIT Voucher API | |  
 | | \- JWT Issuer | | \- HMAC SHA-512 | | \- Vendor Intermediary| |  
 | \+----------+----------+ \+----------+----------+ \+-----------+-----------+ |  
 | | | | |  
 | \+-------------------------+--------------------------+ |  
 | | |  
 | v |  
 | \+----------------------------------+ |  
 | | Handler Service | |  
 | | \- Fast DOM HTML Scraper | |  
 | | \- Official Portal HTTP Ingestion | |  
 | \+------------------+---------------+ |  
 | | |  
 \+---------------------------------------|-----------------------------------------+  
 |  
 \+---------------------------------+---------------------------------+  
 | | |  
 v v v  
\[ PAYSTACK API \] \[ THIRD-PARTY VENDOR API \] \[ OFFICIAL WAEC PORTAL \]  
(MoMo Charge & Webhook) (SellePins / VTpass REST) (eresults.waecgh.org)

## **Technical Stack & Infrastructure Specifications**

| Architectural Layer     | Component Technology           | Design Purpose & Implementation Details                                                                    |
| :---------------------- | :----------------------------- | :--------------------------------------------------------------------------------------------------------- |
| **Mobile Frontend**     | Flutter Framework (Dart)       | Compiles to ahead-of-time (AOT) ARM binary; enforces in-memory state management using Riverpod.            |
| **Edge Gateway**        | NGINX / Kong API Gateway       | Handles TLS 1.3 termination, rate limiting, and mTLS proxying to microservices.                            |
| **Backend Core**        | Rust (Tokio / Actix-Web)       | Microservice architecture delivering zero-cost abstractions, memory safety, and low latency\[cite: 1\].    |
| **Internal Transport**  | gRPC over mTLS (rustls)        | Inter-service communication restricted via mutual TLS and dynamic certificate checks\[cite: 1\].           |
| **Caching & Messaging** | Redis & Apache Kafka           | Redis manages session state and grace-period logs; Kafka processes async transaction pipelines\[cite: 1\]. |
| **Database**            | PostgreSQL (Encrypted at Rest) | Holds encrypted transaction logs, user auth hashes, and payment verification records\[cite: 1\].           |

## **Security, Cryptography & Compliance Infrastructure**

The platform implements a Zero-Trust security model. Raw candidate grades are never written to disk, preventing regulatory data liability and minimizing data breach surfaces.

┌───────────────────────────────────────────────────────────────────────────┐  
│ SECURITY & ENCRYPTION POLICIES │\[cite: 1\]  
├───────────────────────┬───────────────────────────────────────────────────┤  
│ Encryption Standard │ AES-256-GCM with dynamic 96-bit (12-byte) IVs │\[cite: 1\]  
│ In-Transit Protection │ TLS 1.3 client-side; mTLS inter-service │\[cite: 1\]  
│ Certificate Pinning │ SHA-256 SSL public key hashes compiled in Flutter │\[cite: 1\]  
│ Authentication │ Index Number \+ Argon2id hash; RS256 JWT tokens │\[cite: 1\]  
│ Data Privacy Model │ Zero persistent storage of raw student grades │\[cite: 1\]  
│ Memory Handling │ Non-persistent state purged upon user logout │\[cite: 1\]  
└───────────────────────┴───────────────────────────────────────────────────┘

### **Shared Cryptography Crate (Rust Implementation)**

Rust  
// File: microservices/common/src/crypto.rs  
use aes_gcm::{  
 aead::{Aead, KeyInit},  
 Aes256Gcm, Nonce, Key  
};  
use rand::RngCore;

pub struct CryptoEngine {  
 cipher: Aes256Gcm,  
}

impl CryptoEngine {  
 pub fn new(secret_key: &\[u8; 32\]) \-\> Self {  
 let key \= Key::\<Aes256Gcm\>::from_slice(secret_key);  
 let cipher \= Aes256Gcm::new(key);  
 Self { cipher }  
 }

    pub fn encrypt\_payload(&self, plaintext: &\[u8\]) \-\> Result\<(Vec\<u8\>, \[u8; 12\]), String\> {
        let mut nonce\_bytes \= \[0u8; 12\];
        rand::thread\_rng().fill\_bytes(&mut nonce\_bytes);
        let nonce \= Nonce::from\_slice(\&nonce\_bytes);

        let ciphertext \= self.cipher
            .encrypt(nonce, plaintext)
            .map\_err(|e| format\!("AES-256-GCM Encryption Failure: {:?}", e))?;

        Ok((ciphertext, nonce\_bytes))
    }

    pub fn decrypt\_payload(&self, ciphertext: &\[u8\], nonce\_bytes: &\[u8; 12\]) \-\> Result\<Vec\<u8\>, String\> {
        let nonce \= Nonce::from\_slice(nonce\_bytes);
        self.cipher
            .decrypt(nonce, ciphertext)
            .map\_err(|e| format\!("AES-256-GCM Decryption Failure: {:?}", e))?
    }

}

## **Backend Microservices Architecture**

### **Core Microservices Specifications**

- **Auth Service:** Handles user registration, password hashing using Argon2id, and issuance of short-lived RS256 signed JWT tokens\[cite: 1\].
- **Payment Service:** Consumes webhooks from payment processors (e.g., Paystack), verifies cryptographic signatures (HMAC SHA-512), and authorizes voucher acquisition tokens\[cite: 1\].
- **Distributor Service:** Implements a Just-in-Time (JIT) automated intermediary model\[cite: 1\]. Upon payment authorization, it triggers third-party APIs (e.g., SellePins, VTpass) to acquire single-use checker PINs without holding pre-purchased inventory\[cite: 1\].
- **Handler Service:** Receives requested examination parameters and checker credentials, initiates encrypted HTTP connections to the official WAEC portal (eresults.waecgh.org), parses raw HTML payloads into structured JSON data models, and streams results directly to the mobile application\[cite: 1\].
- **Admin Service:** Provides role-based access control (RBAC) endpoints for system diagnostics, transaction log auditing, and infrastructure monitoring via Prometheus metrics\[cite: 1\].

## **Mobile UI/UX Design System & Application Flow**

The frontend application uses an authoritative visual framework designed with custom styling variables.

┌───────────────────────────────────────────────────────────────────────────┐  
│ VISUAL DESIGN SYSTEM TOKENS │  
├───────────────────────┬───────────────────────────────────────────────────┤  
│ Institutional Navy │ \#0A2540 (Primary UI Containers & Headers) │  
│ Mint Accent │ \#00D4B1 (CTA Buttons & High-Grade Indicators) │\[cite: 3\]  
│ Canvas Background │ Light Mode: \#F8FAFC | Dark Mode: \#051424 │\[cite: 3\]  
│ Card Containers │ Light Mode: \#FFFFFF | Dark Mode: \#0D1F35 │\[cite: 3\]  
│ Typography │ Public Sans (Clean, high-legibility sans-serif) │\[cite: 3\]  
└───────────────────────┴───────────────────────────────────────────────────┘

### **Screen Flow & Structure**

\+-----------------------------------+ \+-----------------------------------+  
| WAEC Direct Verification | | Official Candidate Result |\[cite: 3\]  
\+-----------------------------------+ \+-----------------------------------+  
| Candidate Index Number: | | Index: 0021049281 Year: 2026 |\[cite: 3\]  
| \[ 0021049281 \] | | Name: KWAME NKRUMAH |\[cite: 3\]  
| | | Type: WASSCE SCHOOL |\[cite: 3\]  
| Examination Type: | \+-----------------------------------+  
| \[ WASSCE (School) v \] | | SUBJECT | GRADE |\[cite: 3\]  
| | |-------------------|---------------|  
| Examination Year: | | SOCIAL STUDIES | A1 (EXCELLENT)|\[cite: 3\]  
| \[ 2026 v \] | | ENGLISH LANG | B2 (VERY GOOD)|\[cite: 3\]  
| | | CORE MATHEMATICS | A1 (EXCELLENT)|\[cite: 3\]  
| Payment Method: | | INTEGRATED SCI | B3 (GOOD) |\[cite: 3\]  
| (•) Mobile Money ( ) Card | \+-----------------------------------+  
| | | \[ Active 24h Grace Period Active \]|\[cite: 3\]  
| \+-------------------------------+ | | \[ 2 of 3 Uses Remaining \] |\[cite: 3\]  
| | PAY GHc 25.00 & FETCH RESULT | | | |  
| \+-------------------------------+ | | \[ Export PDF \] \[ Save Image \] |\[cite: 3\]  
\+-----------------------------------+ \+-----------------------------------+

> 1. **Auth & Onboarding Screen:** Collects 10-digit candidate index number and password, featuring biometric login integrations via platform keystores.
> 2. **Unified Verification Screen:** Card-based interface capturing Index Number, Exam Type, Exam Year, and Mobile Money/Card payment selections\[cite: 3\].
> 3. **Direct Processing Overlay:** Real-time state progress indicators tracking Payment Confirmation $\\rightarrow$ Third-Party Voucher Provisioning $\\rightarrow$ WAEC Direct Retrieval\[cite: 3\].
> 4. **Official Result Canvas:** Digital rendering replicating official WAEC result layouts, featuring encrypted in-memory subject breakdowns and a top status badge tracking active 24-hour grace period timers.
> 5. **Transaction History Log:** Audit log listing past purchases with dynamic action buttons permitting free re-fetches during an active 24-hour grace period.

## **Production Caveats & Risk Mitigation Matrix**

| Identified Production Risk       | Root Cause Analysis                                                                                      | Mitigation Architecture                                                                                                                                                                                                      |
| :------------------------------- | :------------------------------------------------------------------------------------------------------- | :--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Network Disruption Mid-Fetch** | Connection drops after the voucher is marked used by WAEC, but before the payload reaches local storage. | **Atomic Transaction Logging:** Store encrypted purchase transaction state prior to egress calls; automatically issue re-fetch tokens within the 24-hour grace period if raw payload parsing fails\[cite: 1\].               |
| **Client Memory Dumps**          | Attackers on rooted/jailbroken devices dumping RAM to read raw result payloads.                          | **Binary Obfuscation & Dynamic RAM Purge:** Obfuscate Flutter builds via Dart AOT; isolate result variables inside Riverpod state trees that automatically zero out memory blocks upon screen disposal or app backgrounding. |
| **Local Device Data Loss**       | Uninstalling the application or clearing OS storage permanently erases local records.                    | **Encrypted Remote Grace-Log:** Maintain server-side transaction logs with encrypted index pointers so verified users can re-trigger direct retrieval within the active grace period without repurchase.                     |
| **Voucher API Latency**          | Third-party voucher vendor APIs experience delays or service degradation\[cite: 1\].                     | **Automated Retry & Fallback Routing:** Implement circuit-breaker pattern in the Distributor service with automatic fallback switching to secondary wholesale vendors\[cite: 1\].                                            |

Stakeholder Open Questions & Ghana-Optimized Industry Solutions

1. Scope & Regional Focus
   Stakeholder Question: What is the launch geographic scope, currency model, and targeted examination boards?
   Industry-Grade Solution:
   Ghana-Only Target Scope: The application launches strictly in Ghana. All Nigerian localization, NGN currency logic, and cross-border sub-accounts are explicitly stripped from this initial launch.
   Exam Coverage (BECE & Nwasie): Launch support covers BECE (Junior High), WASSCE School (May/June), and WASSCE Private / Nov-Dec ("Nwasie").
   Pricing & Settlement: Dynamic GHS (Ghana Cedi) pricing managed via the backend config endpoint. Payments route directly through Paystack Ghana to process local Mobile Money rails (MTN MoMo, Telecel Cash, AT Money) alongside local Visa/Mastercard transactions.
2. Vendor Contracts & Inventory Strategy
   Stakeholder Question: Which third-party voucher providers are integrated for Ghana, and what is the failover strategy?
   Industry-Grade Solution:
   Vendor Integrations: Integrates Ghanaian wholesale SMS/Voucher APIs (e.g., SellePins, Ewale, or GHVouchers API) for Just-in-Time (JIT) acquisition of BECE and WASSCE PINs.
   Automated Circuit-Breaker: Implements a circuit-breaker in the Rust Distributor Service.
   Rules: If Primary Vendor returns 3 consecutive HTTP errors, timeout (>3000ms), or an OUT_OF_STOCK signal, the circuit breaker opens for 3 minutes.
   Failover: 100% of voucher requests instantly route to the Secondary Vendor without dropping incoming user transactions.
3. WAEC Portal Integration & Scraping Resilience
   Stakeholder Question: How does the engine query the WAEC Ghana portals (eresults.waecgh.org & ghana.waecdirect.org) safely and handle DOM changes?
   Industry-Grade Solution:
   Target Portals: Ingests HTML payloads from official Ghana endpoints (eresults.waecgh.org for BECE/WASSCE SC and ghana.waecdirect.org for WASSCE Private).
   Decoupled DOM Parser: Rust Handler Service uses decoupled schema validation to parse incoming HTML. If WAEC alters their HTML structure, the parser aborts cleanly, triggers an immediate automated client retry, and fires an alert to engineering.
   Anti-Blocking Strategy: Egress queries use rotated residential proxy IPs within West Africa and randomized browser TLS fingerprints to prevent WAEC Web Application Firewalls (WAF) from rate-limiting the backend gateway.
4. Ghana Mobile Network Reliability & Network Policies
   Stakeholder Question: How does the architecture handle unstable local mobile networks (MTN, Telecel, AT 3G/4G network drops, high packet loss, and high latency)?
   Industry-Grade Solution:
   Exponential Backoff & Jitter Retry Policy: All network requests from the Flutter app to the API gateway enforce exponential backoff with randomized jitter (e.g., base delay 1.5s, max 3 retries) to survive sudden 3G/4G tower handoffs or transient drops.
   Idempotent Transaction Headers: Every payment and fetch request carries an X-Idempotency-Key (UUIDv4) generated by the mobile client. If a user's MoMo connection drops mid-request and they tap "Retry", the backend recognizes the key, preventing double-charging or buying duplicate WAEC vouchers.
   Gzip/Brotli Socket Compression: Payload JSONs are compressed at the NGINX edge gateway to ensure result payloads are under 10KB, allowing quick transmission across congested 2G/3G connections.
5. Gateway Communication Model
   Stakeholder Question: What real-time protocol updates the mobile UI overlay during processing (Payment Verified $\rightarrow$ PIN Acquired $\rightarrow$ Fetching Result)?
   Industry-Grade Solution:
   Protocol Choice: Server-Sent Events (SSE) over HTTP/2 with Client Short-Polling Fallback.
   Why SSE?: Unidirectional, lightweight, native reconnect support, and lower overhead than WebSockets over unstable mobile networks.
   Ghana Network Fallback: If the mobile carrier breaks long-lived HTTP/2 SSE connections (common on congested local towers), the Flutter app gracefully degrades to an adaptive 2-second short-polling query against /transaction/status/{id} until retrieval finishes.
   Summary Matrix for Architecture Appendices
   Category
   Technical Specification
   Operational Target
   Geographic Scope
   Ghana Only
   Single-region focus, local regulatory compliance
   Exam Types
   BECE, WASSCE (School), WASSCE Private ("Nwasie")
   Full coverage for Ghanaian basic & secondary exams
   Payment Gateway
   Paystack Ghana (MTN MoMo, Telecel Cash, AT Money, Visa/MC)
   Local currency (GHS) direct settlement
   Network Resiliency
   Client Idempotency Keys + SSE with Short-Polling Fallback
   High-availability under unstable 3G/4G network conditions
   Data Storage
   Zero Server Storage + Encrypted Local SQLCipher
   100% Client-side ownership, infinite duration until user delete
