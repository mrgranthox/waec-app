import type { Screen } from "../App";

const HISTORY = [
  { id: "0021049281", type: "WASSCE School", year: "2026", date: "12 Sep 2026", time: "09:14 AM", ref: "WDX-2026-48291" },
  { id: "0021049281", type: "WASSCE School", year: "2025", date: "03 Jan 2026", time: "11:52 AM", ref: "WDX-2025-39104" },
  { id: "0021049281", type: "BECE", year: "2022", date: "17 Aug 2022", time: "02:30 PM", ref: "WDX-2022-11847" },
];

export default function HistoryScreen({
  onViewResult,
  onNavigate,
}: {
  onViewResult: () => void;
  onNavigate: (s: Screen) => void;
}) {
  return (
    <div className="flex flex-col pb-4" style={{ background: "#F8FAFC" }}>
      {/* Header */}
      <div className="px-6 pt-6 pb-4" style={{ background: "#0A2540" }}>
        <p className="text-xs font-medium uppercase tracking-widest mb-1" style={{ color: "rgba(0,212,177,0.8)", letterSpacing: "0.14em", fontSize: 9 }}>
          Transaction Log
        </p>
        <h2 className="text-xl font-bold text-white">Saved Results</h2>
        <p className="text-xs mt-1" style={{ color: "rgba(255,255,255,0.4)" }}>
          {HISTORY.length} records stored locally on this device
        </p>
      </div>

      {/* Storage notice */}
      <div
        className="mx-6 mt-4 rounded-xl flex items-center gap-3 px-4 py-3"
        style={{ background: "#fff", border: "1px solid #E2E8F0" }}
      >
        <div
          className="flex items-center justify-center flex-shrink-0"
          style={{ width: 32, height: 32, borderRadius: 8, background: "#F0FDF9" }}
        >
          <svg width="16" height="16" viewBox="0 0 16 16" fill="none">
            <path d="M8 1.5L2 4.5V9C2 12.3 5 15 8 15.5C11 15 14 12.3 14 9V4.5L8 1.5Z" fill="#CCFBF1" stroke="#00D4B1" strokeWidth="1.2"/>
            <path d="M5.5 8.5L7 10L10.5 6.5" stroke="#00D4B1" strokeWidth="1.3" strokeLinecap="round"/>
          </svg>
        </div>
        <div>
          <p className="text-xs font-semibold" style={{ color: "#0A2540" }}>Local Storage Only</p>
          <p className="text-xs" style={{ color: "#94A3B8" }}>All records exist only on this device. No cloud backup.</p>
        </div>
      </div>

      {/* List */}
      <div className="px-6 pt-5 flex flex-col gap-3">
        {HISTORY.map((item, i) => (
          <div
            key={i}
            className="rounded-2xl overflow-hidden"
            style={{ background: "#fff", border: "1px solid #E2E8F0", boxShadow: "0 1px 6px rgba(10,37,64,0.04)" }}
          >
            {/* Card header */}
            <div
              className="flex items-center justify-between px-5 py-3"
              style={{ borderBottom: "1px solid #F1F5F9", background: "#FAFBFC" }}
            >
              <span className="font-semibold text-sm tracking-wider" style={{ color: "#0A2540", fontFamily: "JetBrains Mono", letterSpacing: "0.08em" }}>
                {item.id}
              </span>
              <span
                className="text-xs font-semibold px-2.5 py-1 rounded-full"
                style={{ background: "#F0FDF9", color: "#00856F", border: "1px solid #CCFBF1" }}
              >
                Saved Local
              </span>
            </div>

            {/* Card body */}
            <div className="px-5 py-4">
              <div className="flex items-start justify-between mb-3">
                <div>
                  <p className="text-sm font-semibold" style={{ color: "#0A2540" }}>{item.type}</p>
                  <p className="text-xs mt-0.5" style={{ color: "#64748B" }}>
                    Year {item.year}
                  </p>
                </div>
                <div className="text-right">
                  <p className="text-xs font-medium" style={{ color: "#0A2540" }}>{item.date}</p>
                  <p className="text-xs" style={{ color: "#94A3B8" }}>{item.time}</p>
                </div>
              </div>

              <div className="flex items-center justify-between">
                <span
                  className="text-xs"
                  style={{ color: "#94A3B8", fontFamily: "JetBrains Mono", fontSize: 10 }}
                >
                  REF: {item.ref}
                </span>
                <button
                  onClick={onViewResult}
                  className="flex items-center gap-1.5 rounded-lg px-3 py-2 font-semibold text-xs transition-all active:scale-95"
                  style={{
                    background: "#0A2540",
                    color: "#fff",
                    border: "none",
                    cursor: "pointer",
                    fontFamily: "DM Sans",
                  }}
                >
                  View Stored Result
                  <svg width="12" height="12" viewBox="0 0 12 12" fill="none" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round">
                    <path d="M5 2l4 4-4 4"/>
                  </svg>
                </button>
              </div>
            </div>
          </div>
        ))}
      </div>

      {/* Empty state hint */}
      <div className="flex items-center gap-2 px-6 pt-4">
        <div style={{ flex: 1, height: 1, background: "#E2E8F0" }} />
        <span className="text-xs" style={{ color: "#CBD5E1" }}>End of records</span>
        <div style={{ flex: 1, height: 1, background: "#E2E8F0" }} />
      </div>
    </div>
  );
}
