import { useEffect, useState } from "react";

const STEPS = [
  { label: "Payment Verified", delay: 0 },
  { label: "Querying WAEC Direct Central Server...", delay: 900 },
  { label: "Encrypted Payload Delivered", delay: 2100 },
];

export default function VerificationModal() {
  const [completed, setCompleted] = useState<number[]>([]);
  const [active, setActive] = useState(0);

  useEffect(() => {
    STEPS.forEach((step, i) => {
      setTimeout(() => {
        setActive(i);
        setTimeout(() => {
          setCompleted((prev) => [...prev, i]);
        }, 600);
      }, step.delay);
    });
  }, []);

  return (
    <div
      className="absolute inset-0 flex items-end justify-center"
      style={{
        background: "rgba(10,37,64,0.72)",
        backdropFilter: "blur(4px)",
        zIndex: 50,
      }}
    >
      <div
        className="rounded-t-3xl w-full px-6 pt-6 pb-10"
        style={{ background: "#fff", boxShadow: "0 -8px 40px rgba(10,37,64,0.18)" }}
      >
        {/* Handle */}
        <div className="flex justify-center mb-5">
          <div style={{ width: 36, height: 4, borderRadius: 2, background: "#E2E8F0" }} />
        </div>

        {/* Title */}
        <div className="flex items-center gap-3 mb-6">
          <div
            className="flex items-center justify-center"
            style={{ width: 40, height: 40, borderRadius: 12, background: "#0A2540" }}
          >
            <svg width="20" height="20" viewBox="0 0 20 20" fill="none">
              <path d="M10 2.5L3 5.5V10C3 14 6.2 17.6 10 18.5C13.8 17.6 17 14 17 10V5.5L10 2.5Z" fill="none" stroke="#00D4B1" strokeWidth="1.6"/>
              <path d="M7 10L9 12L13 8" stroke="#00D4B1" strokeWidth="1.6" strokeLinecap="round"/>
            </svg>
          </div>
          <div>
            <h3 className="text-base font-bold" style={{ color: "#0A2540" }}>Verifying Result</h3>
            <p className="text-xs" style={{ color: "#94A3B8" }}>Secure connection to WAEC servers</p>
          </div>
        </div>

        {/* Steps */}
        <div className="flex flex-col gap-1">
          {STEPS.map((step, i) => {
            const done = completed.includes(i);
            const isActive = active === i && !done;

            return (
              <div
                key={i}
                className="flex items-center gap-4 rounded-xl px-4 py-3.5 transition-all"
                style={{
                  background: done ? "#F0FDF9" : isActive ? "#F8FAFC" : "#F8FAFC",
                  border: done ? "1px solid #CCFBF1" : isActive ? "1px solid #E2E8F0" : "1px solid transparent",
                }}
              >
                {/* Indicator */}
                <div
                  className="flex items-center justify-center flex-shrink-0"
                  style={{
                    width: 28,
                    height: 28,
                    borderRadius: "50%",
                    background: done ? "#00D4B1" : isActive ? "#F1F5F9" : "#F1F5F9",
                    border: done ? "none" : isActive ? "2px solid #E2E8F0" : "2px solid #F1F5F9",
                  }}
                >
                  {done ? (
                    <svg width="14" height="14" viewBox="0 0 14 14" fill="none">
                      <path d="M3 7L6 10L11 4.5" stroke="white" strokeWidth="1.8" strokeLinecap="round"/>
                    </svg>
                  ) : isActive ? (
                    <SpinnerDot />
                  ) : (
                    <div style={{ width: 8, height: 8, borderRadius: "50%", background: "#CBD5E1" }} />
                  )}
                </div>

                <span
                  className="text-sm font-medium"
                  style={{ color: done ? "#00856F" : isActive ? "#0A2540" : "#94A3B8", fontFamily: "DM Sans" }}
                >
                  {done ? "✓ " : ""}{step.label}
                </span>
              </div>
            );
          })}
        </div>

        {/* Index number ref */}
        <div
          className="mt-5 rounded-xl px-4 py-3 flex items-center justify-between"
          style={{ background: "#F8FAFC", border: "1px solid #E2E8F0" }}
        >
          <span className="text-xs" style={{ color: "#64748B" }}>Candidate Index</span>
          <span className="text-sm font-semibold" style={{ color: "#0A2540", fontFamily: "JetBrains Mono", letterSpacing: "0.08em" }}>
            0021049281
          </span>
        </div>

        <p className="text-center text-xs mt-4" style={{ color: "#CBD5E1" }}>
          Do not close this screen
        </p>
      </div>
    </div>
  );
}

function SpinnerDot() {
  return (
    <div
      style={{
        width: 12,
        height: 12,
        borderRadius: "50%",
        border: "2px solid #E2E8F0",
        borderTopColor: "#0A2540",
        animation: "spin 0.7s linear infinite",
      }}
    />
  );
}
