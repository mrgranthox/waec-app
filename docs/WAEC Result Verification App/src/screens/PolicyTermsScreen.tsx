export default function PolicyTermsScreen({ onBack }: { onBack: () => void }) {
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
            <h1 className="text-lg font-bold text-white">Terms of Service</h1>
          </div>
        </div>
      </div>

      <div className="px-6 pt-6 flex flex-col gap-5">
        <div className="flex items-center justify-between">
          <span className="text-xs font-semibold uppercase tracking-wider" style={{ color: "#94A3B8", letterSpacing: "0.1em" }}>Effective Date</span>
          <span className="text-xs font-medium" style={{ color: "#0A2540", fontFamily: "JetBrains Mono" }}>01 January 2026</span>
        </div>

        {/* Critical callout */}
        <div
          className="rounded-2xl px-5 py-4"
          style={{ background: "#FFF7ED", border: "1.5px solid #FED7AA" }}
        >
          <div className="flex items-start gap-2 mb-2">
            <svg width="16" height="16" viewBox="0 0 16 16" fill="none" style={{ marginTop: 1, flexShrink: 0 }}>
              <path d="M8 1.5L1 14.5H15L8 1.5Z" fill="#FEF3C7" stroke="#F59E0B" strokeWidth="1.2" strokeLinejoin="round"/>
              <path d="M8 6v4M8 11.5v.5" stroke="#D97706" strokeWidth="1.3" strokeLinecap="round"/>
            </svg>
            <span className="text-sm font-bold" style={{ color: "#92400E" }}>Liability Termination</span>
          </div>
          <p className="text-sm leading-relaxed" style={{ color: "#78350F" }}>
            Once the encrypted result payload is delivered to the user's device, <strong>all operational and security liabilities transfer entirely to the user</strong>. WAEC and its authorised agents bear no further responsibility for the security, accuracy, or misuse of result data post-delivery.
          </p>
        </div>

        <TermsSection title="1. Acceptance of Terms">
          <p>By accessing and using WAEC Direct, you accept and agree to be bound by these Terms of Service and all applicable laws and regulations of the Republic of Ghana. If you do not agree, you are prohibited from using this service.</p>
        </TermsSection>

        <TermsSection title="2. Service Description">
          <p>WAEC Direct provides a paid result-verification service enabling candidates to retrieve their official WASSCE and BECE results from the WAEC Central Examination Database. Each query constitutes a separate transaction.</p>
        </TermsSection>

        <TermsSection title="3. Payment Terms">
          <p>A non-refundable fee of GHc 25.00 is charged per result query, regardless of whether a result is found or the candidate's performance. By initiating payment, the user acknowledges understanding of this policy. WAEC accepts no liability for duplicate payments arising from user error.</p>
        </TermsSection>

        <TermsSection title="4. Result Authenticity">
          <p>Results delivered via WAEC Direct are fetched directly from the WAEC Central Examination Database and are authentic at the time of delivery. WAEC reserves the right to withhold, correct, or cancel any result pending investigation, in accordance with the WAEC Examination Rules and Regulations.</p>
        </TermsSection>

        <TermsSection title="5. Prohibited Use">
          <p>Users may not: (a) attempt to query results using a Candidate Index Number that does not belong to them; (b) use automated tools, bots, or scrapers; (c) redistribute, sell, or commercially exploit result data; (d) attempt to circumvent payment systems.</p>
        </TermsSection>

        <TermsSection title="6. Device Security">
          <p>Following result delivery, the user is solely responsible for securing all data stored on their device. WAEC Direct does not offer data recovery services. Users are advised to use strong device passwords and screen locks.</p>
        </TermsSection>

        <TermsSection title="7. Governing Law">
          <p>These Terms are governed by the laws of the Republic of Ghana. Any disputes shall be subject to the exclusive jurisdiction of the courts of Ghana.</p>
        </TermsSection>

        <TermsSection title="8. Amendments">
          <p>WAEC reserves the right to amend these Terms at any time. Continued use of the application following any such amendment constitutes acceptance of the revised Terms.</p>
        </TermsSection>
      </div>
    </div>
  );
}

function TermsSection({ title, children }: { title: string; children: React.ReactNode }) {
  return (
    <div className="rounded-2xl p-5" style={{ background: "#fff", border: "1px solid #E2E8F0" }}>
      <h3 className="text-sm font-bold mb-2.5" style={{ color: "#0A2540" }}>{title}</h3>
      <div className="text-sm leading-relaxed" style={{ color: "#475569" }}>
        {children}
      </div>
    </div>
  );
}
