export default function PolicyPrivacyScreen({ onBack }: { onBack: () => void }) {
  return (
    <div className="flex flex-col pb-8" style={{ background: "#F8FAFC" }}>
      {/* Header */}
      <div style={{ background: "#0A2540" }}>
        <div className="flex items-center gap-3 px-5 pt-5 pb-5">
          <button
            onClick={onBack}
            style={{ background: "rgba(255,255,255,0.08)", border: "none", borderRadius: 10, width: 34, height: 34, display: "flex", alignItems: "center", justifyContent: "center", cursor: "pointer" }}
          >
            <svg width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="white" strokeWidth="1.8" strokeLinecap="round">
              <path d="M10 4L6 8L10 12"/>
            </svg>
          </button>
          <div>
            <p className="text-xs font-medium uppercase tracking-widest" style={{ color: "rgba(0,212,177,0.8)", fontSize: 9, letterSpacing: "0.14em" }}>Legal</p>
            <h1 className="text-lg font-bold text-white">Privacy Policy</h1>
          </div>
        </div>
      </div>

      <div className="px-6 pt-6 flex flex-col gap-5">
        <MetaRow label="Version" value="2.4.1" />
        <MetaRow label="Last Updated" value="01 September 2026" />
        <MetaRow label="Jurisdiction" value="Republic of Ghana" />

        {/* Highlight callout */}
        <div
          className="rounded-2xl px-5 py-4"
          style={{ background: "#F0FDF9", border: "1.5px solid #CCFBF1" }}
        >
          <div className="flex items-center gap-2 mb-2">
            <svg width="16" height="16" viewBox="0 0 16 16" fill="none">
              <path d="M8 1.5L2 4V8C2 11.7 5.1 15 8 15.5C10.9 15 14 11.7 14 8V4L8 1.5Z" fill="#CCFBF1" stroke="#00D4B1" strokeWidth="1.2"/>
              <path d="M5.5 8L7 9.5L10.5 6" stroke="#00D4B1" strokeWidth="1.3" strokeLinecap="round"/>
            </svg>
            <span className="text-sm font-bold" style={{ color: "#00856F" }}>Zero Server Storage</span>
          </div>
          <p className="text-sm leading-relaxed" style={{ color: "#065F46" }}>
            Student grades pass strictly <strong>in-transit</strong> and are purged immediately post-transmission. WAEC Direct maintains <strong>no persistent record</strong> of any candidate result on any server, cloud infrastructure, or third-party service.
          </p>
        </div>

        <PolicySection title="1. Data Collection">
          <p>WAEC Direct collects only the Candidate Index Number submitted by the user for the sole purpose of querying the WAEC Central Examination Database. No personal identifiers, biographic data, or profile information are collected or retained by this application.</p>
        </PolicySection>

        <PolicySection title="2. Data Processing">
          <p>All result data is processed exclusively on the user's local device. The application establishes a one-time encrypted connection to the WAEC API Gateway, retrieves the examination result payload, renders it on-device, and immediately purges all server-side session data upon payload delivery confirmation.</p>
        </PolicySection>

        <PolicySection title="3. Local Storage">
          <p>A user may elect to save their result locally on their device. This storage is entirely within the user's control. The application does not transmit, backup, or synchronize locally stored data to any external service. The user is solely responsible for the security of locally stored data.</p>
        </PolicySection>

        <PolicySection title="4. Third-Party Services">
          <p>Payment processing is handled by licensed mobile money operators and card-payment gateways operating under Bank of Ghana regulations. WAEC Direct does not store payment credentials. Transaction confirmations are passed to the WAEC verification server as proof of payment only.</p>
        </PolicySection>

        <PolicySection title="5. Biometric Data">
          <p>Biometric authentication (fingerprint and Face ID) is performed entirely through the device's native operating system APIs. Biometric data never leaves the device and is not accessible to WAEC Direct.</p>
        </PolicySection>

        <PolicySection title="6. Data Subject Rights">
          <p>Under Ghana's Data Protection Act, 2012 (Act 843), users have the right to access, correct, and erasure of any personally identifiable data held by WAEC. Requests may be directed to the WAEC National Office Data Protection Officer at the contact addresses provided in the About section.</p>
        </PolicySection>

        <PolicySection title="7. Contact">
          <p>Data Protection Officer · West Africa Examinations Council · P.O. Box GP 125, Accra, Ghana · dpo@waec.org.gh</p>
        </PolicySection>
      </div>
    </div>
  );
}

function PolicySection({ title, children }: { title: string; children: React.ReactNode }) {
  return (
    <div className="rounded-2xl p-5" style={{ background: "#fff", border: "1px solid #E2E8F0" }}>
      <h3 className="text-sm font-bold mb-2.5" style={{ color: "#0A2540" }}>{title}</h3>
      <div className="text-sm leading-relaxed" style={{ color: "#475569" }}>
        {children}
      </div>
    </div>
  );
}

function MetaRow({ label, value }: { label: string; value: string }) {
  return (
    <div className="flex items-center justify-between">
      <span className="text-xs font-semibold uppercase tracking-wider" style={{ color: "#94A3B8", letterSpacing: "0.1em" }}>{label}</span>
      <span className="text-xs font-medium" style={{ color: "#0A2540", fontFamily: "JetBrains Mono" }}>{value}</span>
    </div>
  );
}
