import { useState } from "react";
import type { Screen } from "../App";

const EXAM_TYPES = ["WASSCE School", "WASSCE Private", "BECE"];
const EXAM_YEARS = ["2026", "2025", "2024", "2023", "2022", "2021"];

export default function HomeScreen({
  onFetch,
  onNavigate,
}: {
  onFetch: () => void;
  onNavigate: (s: Screen) => void;
}) {
  const [examType, setExamType] = useState("WASSCE School");
  const [examYear, setExamYear] = useState("2026");
  const [payMethod, setPayMethod] = useState<"momo" | "card">("momo");

  return (
    <div className="flex flex-col pb-4" style={{ background: "#F8FAFC" }}>
      {/* Top bar */}
      <div
        className="flex items-center justify-between px-6 py-4"
        style={{ background: "#0A2540" }}
      >
        <div>
          <p className="text-xs font-medium tracking-widest uppercase" style={{ color: "rgba(0,212,177,0.8)", letterSpacing: "0.14em", fontSize: 9 }}>
            Active Session
          </p>
          <p className="font-semibold text-white tracking-wider" style={{ fontFamily: "JetBrains Mono", fontSize: 16, letterSpacing: "0.08em" }}>
            0021049281
          </p>
        </div>
        <div
          className="rounded-lg px-3 py-1.5 flex items-center gap-1.5"
          style={{ background: "rgba(0,212,177,0.12)", border: "1px solid rgba(0,212,177,0.25)" }}
        >
          <div style={{ width: 6, height: 6, borderRadius: "50%", background: "#00D4B1" }} />
          <span className="text-xs font-medium" style={{ color: "#00D4B1" }}>Authenticated</span>
        </div>
      </div>

      {/* Section label */}
      <div className="px-6 pt-6 pb-3">
        <h2 className="text-lg font-bold" style={{ color: "#0A2540" }}>Result Verification</h2>
        <p className="text-xs mt-0.5" style={{ color: "#94A3B8" }}>Complete all fields to fetch your official result</p>
      </div>

      {/* Main card */}
      <div className="px-6">
        <div
          className="rounded-2xl overflow-hidden"
          style={{ background: "#fff", border: "1px solid #E2E8F0", boxShadow: "0 2px 16px rgba(10,37,64,0.06)" }}
        >
          {/* Index number field */}
          <div className="px-5 pt-5 pb-4" style={{ borderBottom: "1px solid #F1F5F9" }}>
            <FieldLabel>Index Number</FieldLabel>
            <div
              className="flex items-center rounded-xl px-4 gap-3 mt-2"
              style={{ background: "#F8FAFC", border: "1.5px solid #E2E8F0", height: 50 }}
            >
              <svg width="14" height="14" viewBox="0 0 14 14" fill="none" stroke="#94A3B8" strokeWidth="1.4" strokeLinecap="round">
                <rect x="1.5" y="2" width="11" height="10" rx="1.5"/>
                <path d="M4 6h6M4 9h4"/>
              </svg>
              <span className="text-sm font-medium" style={{ color: "#0A2540", fontFamily: "JetBrains Mono", letterSpacing: "0.1em" }}>
                0021049281
              </span>
              <span className="ml-auto text-xs px-2 py-0.5 rounded-md" style={{ background: "#F0FDF9", color: "#00B89A", border: "1px solid #CCFBF1", fontFamily: "DM Sans", fontSize: 10, fontWeight: 600 }}>
                LOCKED
              </span>
            </div>
          </div>

          {/* Exam Type */}
          <div className="px-5 py-4" style={{ borderBottom: "1px solid #F1F5F9" }}>
            <FieldLabel>Examination Type</FieldLabel>
            <div className="relative mt-2">
              <select
                value={examType}
                onChange={(e) => setExamType(e.target.value)}
                className="w-full rounded-xl px-4 text-sm font-medium appearance-none outline-none"
                style={{
                  background: "#F8FAFC",
                  border: "1.5px solid #E2E8F0",
                  height: 50,
                  color: "#0A2540",
                  fontFamily: "DM Sans",
                  cursor: "pointer",
                  paddingRight: 40,
                }}
              >
                {EXAM_TYPES.map((t) => (
                  <option key={t} value={t}>{t}</option>
                ))}
              </select>
              <svg
                className="absolute right-4 top-1/2 -translate-y-1/2 pointer-events-none"
                width="14" height="14" viewBox="0 0 14 14" fill="none" stroke="#94A3B8" strokeWidth="1.5" strokeLinecap="round"
              >
                <path d="M3 5L7 9L11 5"/>
              </svg>
            </div>
          </div>

          {/* Exam Year */}
          <div className="px-5 py-4" style={{ borderBottom: "1px solid #F1F5F9" }}>
            <FieldLabel>Examination Year</FieldLabel>
            <div className="relative mt-2">
              <select
                value={examYear}
                onChange={(e) => setExamYear(e.target.value)}
                className="w-full rounded-xl px-4 text-sm font-medium appearance-none outline-none"
                style={{
                  background: "#F8FAFC",
                  border: "1.5px solid #E2E8F0",
                  height: 50,
                  color: "#0A2540",
                  fontFamily: "DM Sans",
                  cursor: "pointer",
                  paddingRight: 40,
                }}
              >
                {EXAM_YEARS.map((y) => (
                  <option key={y} value={y}>{y}</option>
                ))}
              </select>
              <svg
                className="absolute right-4 top-1/2 -translate-y-1/2 pointer-events-none"
                width="14" height="14" viewBox="0 0 14 14" fill="none" stroke="#94A3B8" strokeWidth="1.5" strokeLinecap="round"
              >
                <path d="M3 5L7 9L11 5"/>
              </svg>
            </div>
          </div>

          {/* Payment Method */}
          <div className="px-5 py-4 pb-5">
            <FieldLabel>Payment Method</FieldLabel>
            <div className="flex gap-3 mt-2">
              {(["momo", "card"] as const).map((method) => {
                const active = payMethod === method;
                return (
                  <button
                    key={method}
                    onClick={() => setPayMethod(method)}
                    className="flex-1 flex items-center gap-2.5 rounded-xl px-4 transition-all"
                    style={{
                      height: 50,
                      background: active ? "#0A2540" : "#F8FAFC",
                      border: active ? "1.5px solid #0A2540" : "1.5px solid #E2E8F0",
                      cursor: "pointer",
                    }}
                  >
                    <div
                      style={{
                        width: 16,
                        height: 16,
                        borderRadius: "50%",
                        border: active ? "2px solid #00D4B1" : "2px solid #CBD5E1",
                        background: active ? "#00D4B1" : "transparent",
                        flexShrink: 0,
                        display: "flex",
                        alignItems: "center",
                        justifyContent: "center",
                      }}
                    >
                      {active && <div style={{ width: 6, height: 6, borderRadius: "50%", background: "#0A2540" }} />}
                    </div>
                    <span className="text-sm font-medium" style={{ color: active ? "#fff" : "#0A2540", fontFamily: "DM Sans" }}>
                      {method === "momo" ? "Mobile Money" : "Card"}
                    </span>
                  </button>
                );
              })}
            </div>
          </div>
        </div>
      </div>

      {/* CTA */}
      <div className="px-6 pt-4">
        <button
          onClick={onFetch}
          className="w-full rounded-xl font-semibold text-sm transition-all active:scale-95 flex items-center justify-center gap-3"
          style={{
            height: 56,
            background: "#0A2540",
            color: "#fff",
            border: "none",
            cursor: "pointer",
            fontFamily: "DM Sans",
            letterSpacing: "0.01em",
          }}
        >
          <svg width="18" height="18" viewBox="0 0 18 18" fill="none">
            <path d="M3 9h12M3 5h8M3 13h6" stroke="#00D4B1" strokeWidth="1.8" strokeLinecap="round"/>
          </svg>
          Pay GHc 25.00 &amp; Fetch Result
        </button>

        {/* Disclaimer */}
        <div className="flex items-start gap-2 mt-3 px-1">
          <svg width="12" height="12" viewBox="0 0 12 12" fill="none" style={{ marginTop: 1, flexShrink: 0 }}>
            <circle cx="6" cy="6" r="5.5" fill="none" stroke="#CBD5E1" strokeWidth="1"/>
            <path d="M6 5v3M6 3.5v.5" stroke="#CBD5E1" strokeWidth="1.2" strokeLinecap="round"/>
          </svg>
          <p className="text-xs leading-relaxed" style={{ color: "#94A3B8" }}>
            Payment is non-refundable. Result is stored locally on this device only. No server retention.
          </p>
        </div>
      </div>
    </div>
  );
}

function FieldLabel({ children }: { children: React.ReactNode }) {
  return (
    <span className="text-xs font-semibold uppercase tracking-wider" style={{ color: "#64748B", letterSpacing: "0.1em" }}>
      {children}
    </span>
  );
}
