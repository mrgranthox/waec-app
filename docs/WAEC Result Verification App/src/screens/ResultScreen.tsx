import { useState } from "react";

const SUBJECTS = [
  { name: "ENGLISH LANGUAGE", grade: "A1", label: "EXCELLENT" },
  { name: "CORE MATHEMATICS", grade: "B2", label: "VERY GOOD" },
  { name: "INTEGRATED SCIENCE", grade: "B3", label: "GOOD" },
  { name: "SOCIAL STUDIES", grade: "A1", label: "EXCELLENT" },
  { name: "ELECTIVE MATHS", grade: "B2", label: "VERY GOOD" },
  { name: "ECONOMICS", grade: "C4", label: "CREDIT" },
  { name: "PHYSICS", grade: "B3", label: "GOOD" },
  { name: "CHEMISTRY", grade: "A1", label: "EXCELLENT" },
];

const gradeColors: Record<string, { bg: string; text: string; border: string }> = {
  A1: { bg: "#F0FDF9", text: "#00856F", border: "#CCFBF1" },
  B2: { bg: "#EFF6FF", text: "#1D4ED8", border: "#BFDBFE" },
  B3: { bg: "#F0F9FF", text: "#0369A1", border: "#BAE6FD" },
  C4: { bg: "#FFFBEB", text: "#92400E", border: "#FDE68A" },
  C5: { bg: "#FFFBEB", text: "#92400E", border: "#FDE68A" },
  C6: { bg: "#FFF7ED", text: "#9A3412", border: "#FED7AA" },
  D7: { bg: "#FFF7ED", text: "#C2410C", border: "#FFEDD5" },
  E8: { bg: "#FEF2F2", text: "#B91C1C", border: "#FECACA" },
  F9: { bg: "#FEF2F2", text: "#991B1B", border: "#FCA5A5" },
};

export default function ResultScreen({ onBack }: { onBack: () => void }) {
  const [cleared, setCleared] = useState(false);

  if (cleared) {
    return (
      <div className="flex flex-col items-center justify-center px-8" style={{ minHeight: 700 }}>
        <div
          className="rounded-2xl p-8 flex flex-col items-center text-center"
          style={{ background: "#fff", border: "1px solid #E2E8F0", width: "100%" }}
        >
          <div
            className="flex items-center justify-center mb-4"
            style={{ width: 56, height: 56, borderRadius: 14, background: "#F1F5F9" }}
          >
            <svg width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="#94A3B8" strokeWidth="1.8" strokeLinecap="round">
              <path d="M3 6h18M8 6V4h8v2M19 6l-1 14H6L5 6"/>
            </svg>
          </div>
          <h3 className="text-base font-bold mb-2" style={{ color: "#0A2540" }}>Record Cleared</h3>
          <p className="text-sm mb-6" style={{ color: "#64748B" }}>All locally stored result data has been permanently erased from this device.</p>
          <button
            onClick={onBack}
            className="rounded-xl px-8 py-3 font-semibold text-sm"
            style={{ background: "#0A2540", color: "#fff", border: "none", cursor: "pointer" }}
          >
            Return to Home
          </button>
        </div>
      </div>
    );
  }

  return (
    <div className="flex flex-col pb-6" style={{ background: "#F8FAFC" }}>
      {/* Header */}
      <div style={{ background: "#0A2540" }}>
        <div className="flex items-center px-5 pt-4 pb-3 gap-3">
          <button
            onClick={onBack}
            style={{ background: "rgba(255,255,255,0.08)", border: "none", borderRadius: 10, width: 34, height: 34, display: "flex", alignItems: "center", justifyContent: "center", cursor: "pointer" }}
          >
            <svg width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="white" strokeWidth="1.8" strokeLinecap="round">
              <path d="M10 4L6 8L10 12"/>
            </svg>
          </button>
          <div>
            <p className="text-xs font-medium" style={{ color: "rgba(0,212,177,0.8)", letterSpacing: "0.1em", fontSize: 9 }}>OFFICIAL RESULT</p>
            <p className="text-sm font-bold text-white tracking-wide" style={{ fontFamily: "JetBrains Mono", letterSpacing: "0.08em" }}>0021049281</p>
          </div>
          <div className="ml-auto text-right">
            <p className="text-xs font-semibold text-white">WASSCE School</p>
            <p className="text-xs" style={{ color: "rgba(255,255,255,0.5)" }}>Year 2026</p>
          </div>
        </div>

        {/* Storage notice */}
        <div className="flex justify-center pb-4">
          <div
            className="flex items-center gap-2 rounded-full px-4 py-1.5"
            style={{ background: "rgba(0,212,177,0.12)", border: "1px solid rgba(0,212,177,0.25)" }}
          >
            <svg width="12" height="12" viewBox="0 0 12 12" fill="none">
              <circle cx="6" cy="6" r="5.5" fill="#00D4B1" opacity="0.2"/>
              <path d="M3.5 6L5.5 8L8.5 4.5" stroke="#00D4B1" strokeWidth="1.4" strokeLinecap="round"/>
            </svg>
            <span className="text-xs font-medium" style={{ color: "#00D4B1" }}>Saved Locally to Device</span>
          </div>
        </div>
      </div>

      {/* Divider info row */}
      <div
        className="flex items-center justify-between px-5 py-3"
        style={{ background: "#fff", borderBottom: "1px solid #E2E8F0" }}
      >
        <div className="flex items-center gap-2">
          <svg width="14" height="14" viewBox="0 0 14 14" fill="none">
            <path d="M7 1L1.5 3.5V7C1.5 10.1 4 12.9 7 13.5C10 12.9 12.5 10.1 12.5 7V3.5L7 1Z" fill="#F0FDF9" stroke="#00D4B1" strokeWidth="1.2"/>
            <path d="M4.5 7L6.3 8.8L9.5 5.5" stroke="#00D4B1" strokeWidth="1.2" strokeLinecap="round"/>
          </svg>
          <span className="text-xs font-semibold" style={{ color: "#0A2540" }}>WAEC Verified Result</span>
        </div>
        <span className="text-xs" style={{ color: "#94A3B8", fontFamily: "JetBrains Mono", fontSize: 10 }}>
          REF: WDX-2026-{Math.floor(Math.random() * 90000 + 10000)}
        </span>
      </div>

      {/* Subjects table */}
      <div className="px-5 pt-4">
        <div
          className="rounded-2xl overflow-hidden"
          style={{ background: "#fff", border: "1px solid #E2E8F0" }}
        >
          {/* Column headers */}
          <div
            className="flex items-center px-5 py-3"
            style={{ background: "#F8FAFC", borderBottom: "1px solid #E2E8F0" }}
          >
            <span className="flex-1 text-xs font-semibold uppercase tracking-wider" style={{ color: "#64748B", letterSpacing: "0.1em" }}>
              Subject
            </span>
            <span className="text-xs font-semibold uppercase tracking-wider" style={{ color: "#64748B", letterSpacing: "0.1em" }}>
              Grade
            </span>
          </div>

          {SUBJECTS.map((s, i) => {
            const c = gradeColors[s.grade] ?? gradeColors["C4"];
            return (
              <div
                key={s.name}
                className="flex items-center px-5 py-3.5"
                style={{
                  borderBottom: i < SUBJECTS.length - 1 ? "1px solid #F1F5F9" : "none",
                }}
              >
                <div className="flex-1 pr-3">
                  <p className="text-sm font-medium" style={{ color: "#0A2540", fontFamily: "DM Sans" }}>
                    {s.name}
                  </p>
                </div>
                <div
                  className="rounded-lg px-3 py-1.5 flex items-center gap-1.5"
                  style={{ background: c.bg, border: `1px solid ${c.border}`, minWidth: 110, justifyContent: "center" }}
                >
                  <span className="font-bold text-sm" style={{ color: c.text, fontFamily: "JetBrains Mono" }}>
                    {s.grade}
                  </span>
                  <span className="text-xs font-medium" style={{ color: c.text, fontSize: 10 }}>
                    {s.label}
                  </span>
                </div>
              </div>
            );
          })}
        </div>
      </div>

      {/* Overall summary */}
      <div className="px-5 pt-4">
        <div
          className="rounded-xl px-5 py-4 flex items-center justify-between"
          style={{ background: "#0A2540" }}
        >
          <div>
            <p className="text-xs font-medium" style={{ color: "rgba(255,255,255,0.5)" }}>Overall Performance</p>
            <p className="text-sm font-bold text-white mt-0.5">8 Subjects · 3 Distinctions</p>
          </div>
          <div
            className="rounded-xl px-4 py-2 text-center"
            style={{ background: "rgba(0,212,177,0.15)", border: "1px solid rgba(0,212,177,0.3)" }}
          >
            <p className="text-xs font-medium" style={{ color: "#00D4B1" }}>Aggregate</p>
            <p className="text-lg font-bold" style={{ color: "#00D4B1", fontFamily: "JetBrains Mono" }}>14</p>
          </div>
        </div>
      </div>

      {/* Action toolbar */}
      <div className="flex gap-3 px-5 pt-4">
        <button
          className="flex-1 flex items-center justify-center gap-2 rounded-xl font-semibold text-sm transition-all active:scale-95"
          style={{
            height: 50,
            background: "#fff",
            color: "#0A2540",
            border: "1.5px solid #0A2540",
            cursor: "pointer",
            fontFamily: "DM Sans",
          }}
        >
          <svg width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round">
            <path d="M3 12h10M8 2v7M5 6l3 3 3-3"/>
          </svg>
          Export PDF
        </button>
        <button
          onClick={() => setCleared(true)}
          className="flex-1 flex items-center justify-center gap-2 rounded-xl font-semibold text-sm transition-all active:scale-95"
          style={{
            height: 50,
            background: "#FEF2F2",
            color: "#B91C1C",
            border: "1.5px solid #FECACA",
            cursor: "pointer",
            fontFamily: "DM Sans",
          }}
        >
          <svg width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round">
            <path d="M3 4h10M6 4V3h4v1M12 4l-.8 9.5H4.8L4 4"/>
          </svg>
          Clear Record
        </button>
      </div>
    </div>
  );
}
