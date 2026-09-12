import type { Screen } from "../App";

export default function AboutScreen({ onNavigate }: { onNavigate: (s: Screen) => void }) {
  return (
    <div className="flex flex-col pb-8" style={{ background: "#F8FAFC" }}>
      {/* Header */}
      <div
        className="flex flex-col items-center pt-8 pb-8"
        style={{ background: "#0A2540" }}
      >
        <div
          className="flex items-center justify-center mb-4"
          style={{ width: 64, height: 64, borderRadius: 16, background: "rgba(0,212,177,0.12)", border: "1.5px solid rgba(0,212,177,0.25)" }}
        >
          <svg width="34" height="34" viewBox="0 0 34 34" fill="none">
            <path d="M17 3L5 8.5V17C5 23.9 10.6 30.2 17 31.5C23.4 30.2 29 23.9 29 17V8.5L17 3Z" fill="rgba(0,212,177,0.15)" stroke="#00D4B1" strokeWidth="1.6" strokeLinejoin="round"/>
            <path d="M11 17L15 21L23 13" stroke="#00D4B1" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"/>
          </svg>
        </div>
        <h1 className="text-xl font-bold text-white">WAEC Direct</h1>
        <p className="text-xs mt-1" style={{ color: "rgba(255,255,255,0.45)" }}>Official Result Verification Application</p>
        <div
          className="mt-3 rounded-full px-4 py-1.5 flex items-center gap-2"
          style={{ background: "rgba(0,212,177,0.12)", border: "1px solid rgba(0,212,177,0.2)" }}
        >
          <div style={{ width: 6, height: 6, borderRadius: "50%", background: "#00D4B1" }} />
          <span className="text-xs font-medium" style={{ color: "#00D4B1", fontFamily: "JetBrains Mono" }}>v3.1.4 · Build 20260901</span>
        </div>
      </div>

      <div className="px-6 pt-6 flex flex-col gap-4">
        {/* Compliance card */}
        <div
          className="rounded-2xl p-5"
          style={{ background: "#fff", border: "1px solid #E2E8F0" }}
        >
          <SectionLabel>System Compliance</SectionLabel>
          <div className="mt-3 flex flex-col gap-2">
            <ComplianceBadge label="WAEC API Gateway v2" status="Certified" ok />
            <ComplianceBadge label="Ghana Data Protection Act 2012" status="Compliant" ok />
            <ComplianceBadge label="TLS 1.3 Encryption" status="Active" ok />
            <ComplianceBadge label="NCA Type Approval" status="Approved" ok />
            <ComplianceBadge label="Bank of Ghana PSP License" status="Licensed" ok />
          </div>
        </div>

        {/* App info */}
        <div
          className="rounded-2xl p-5"
          style={{ background: "#fff", border: "1px solid #E2E8F0" }}
        >
          <SectionLabel>Application Information</SectionLabel>
          <div className="mt-3 flex flex-col gap-2.5">
            <InfoRow label="Publisher" value="WAEC Ghana" />
            <InfoRow label="Platform" value="Android / iOS" />
            <InfoRow label="Version" value="3.1.4" />
            <InfoRow label="Build" value="20260901.1" />
            <InfoRow label="API Version" value="WAEC-GW/2.8" />
            <InfoRow label="Min OS" value="Android 9+ / iOS 15+" />
          </div>
        </div>

        {/* Support */}
        <div
          className="rounded-2xl p-5"
          style={{ background: "#fff", border: "1px solid #E2E8F0" }}
        >
          <SectionLabel>National Office Support</SectionLabel>
          <div className="mt-3 flex flex-col gap-3">
            <ContactItem
              icon={
                <svg width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="#0A2540" strokeWidth="1.5" strokeLinecap="round">
                  <path d="M2 3h12v10H2zM2 3l6 5 6-5"/>
                </svg>
              }
              label="Helpdesk Email"
              value="helpdesk@waec.org.gh"
            />
            <ContactItem
              icon={
                <svg width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="#0A2540" strokeWidth="1.5" strokeLinecap="round">
                  <path d="M3 2.5C3 2.5 2 5 3.5 6.5L5 8C5 8 6 7 6.5 7.5L8.5 9.5C9 10 8 11 8 11C9.5 12.5 12.5 11.5 13.5 11.5V9.5L11 9L10 10L6 6L7 5L6.5 2.5H3Z"/>
                </svg>
              }
              label="Toll-Free Helpline"
              value="0800-222-9232"
            />
            <ContactItem
              icon={
                <svg width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="#0A2540" strokeWidth="1.5" strokeLinecap="round">
                  <circle cx="8" cy="8" r="6"/>
                  <path d="M8 4.5v4l2.5 2"/>
                </svg>
              }
              label="Support Hours"
              value="Mon–Fri · 08:00–17:00 GMT"
            />
            <ContactItem
              icon={
                <svg width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="#0A2540" strokeWidth="1.5" strokeLinecap="round">
                  <path d="M8 2C5.2 2 3 4.2 3 7C3 10.5 8 14 8 14C8 14 13 10.5 13 7C13 4.2 10.8 2 8 2Z"/>
                  <circle cx="8" cy="7" r="1.8"/>
                </svg>
              }
              label="Head Office"
              value="P.O. Box GP 125, Accra"
            />
          </div>
        </div>

        {/* Legal links */}
        <div className="flex flex-col gap-2">
          <PolicyLink label="Privacy Policy — Data Handling & Transience" onPress={() => onNavigate("privacy")} />
          <PolicyLink label="Terms of Service & Liability Statement" onPress={() => onNavigate("terms")} />
        </div>

        {/* Footer */}
        <p className="text-center text-xs py-2" style={{ color: "#CBD5E1" }}>
          © 2026 West Africa Examinations Council · All Rights Reserved
        </p>
      </div>
    </div>
  );
}

function SectionLabel({ children }: { children: React.ReactNode }) {
  return (
    <span className="text-xs font-semibold uppercase tracking-wider" style={{ color: "#64748B", letterSpacing: "0.1em" }}>
      {children}
    </span>
  );
}

function ComplianceBadge({ label, status, ok }: { label: string; status: string; ok: boolean }) {
  return (
    <div className="flex items-center justify-between">
      <span className="text-sm" style={{ color: "#475569" }}>{label}</span>
      <div
        className="flex items-center gap-1.5 rounded-full px-3 py-1"
        style={{
          background: ok ? "#F0FDF9" : "#FEF2F2",
          border: `1px solid ${ok ? "#CCFBF1" : "#FECACA"}`,
        }}
      >
        <div style={{ width: 5, height: 5, borderRadius: "50%", background: ok ? "#00D4B1" : "#EF4444" }} />
        <span className="text-xs font-semibold" style={{ color: ok ? "#00856F" : "#B91C1C" }}>{status}</span>
      </div>
    </div>
  );
}

function InfoRow({ label, value }: { label: string; value: string }) {
  return (
    <div className="flex items-center justify-between">
      <span className="text-sm" style={{ color: "#94A3B8" }}>{label}</span>
      <span className="text-sm font-medium" style={{ color: "#0A2540" }}>{value}</span>
    </div>
  );
}

function ContactItem({ icon, label, value }: { icon: React.ReactNode; label: string; value: string }) {
  return (
    <div className="flex items-center gap-3">
      <div
        className="flex items-center justify-center flex-shrink-0"
        style={{ width: 34, height: 34, borderRadius: 9, background: "#F8FAFC", border: "1px solid #E2E8F0" }}
      >
        {icon}
      </div>
      <div>
        <p className="text-xs" style={{ color: "#94A3B8" }}>{label}</p>
        <p className="text-sm font-medium" style={{ color: "#0A2540" }}>{value}</p>
      </div>
    </div>
  );
}

function PolicyLink({ label, onPress }: { label: string; onPress: () => void }) {
  return (
    <button
      onClick={onPress}
      className="w-full flex items-center justify-between rounded-xl px-5 py-3.5 text-left transition-all"
      style={{ background: "#fff", border: "1px solid #E2E8F0", cursor: "pointer" }}
    >
      <span className="text-sm font-medium" style={{ color: "#0A2540" }}>{label}</span>
      <svg width="14" height="14" viewBox="0 0 14 14" fill="none" stroke="#94A3B8" strokeWidth="1.6" strokeLinecap="round">
        <path d="M5 3L9 7L5 11"/>
      </svg>
    </button>
  );
}
