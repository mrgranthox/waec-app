import { useState } from "react";

export default function AuthScreen({ onLogin }: { onLogin: () => void }) {
  const [index, setIndex] = useState("");
  const [pin, setPin] = useState("");
  const [pinVisible, setPinVisible] = useState(false);
  const [error, setError] = useState("");

  const handleLogin = () => {
    if (index.length !== 10 || !/^\d+$/.test(index)) {
      setError("Index Number must be exactly 10 digits.");
      return;
    }
    if (pin.length < 4) {
      setError("Enter your password or PIN.");
      return;
    }
    setError("");
    onLogin();
  };

  return (
    <div className="flex flex-col" style={{ minHeight: 780, background: "#F8FAFC" }}>
      {/* Header band */}
      <div
        className="flex flex-col items-center pt-12 pb-10"
        style={{ background: "#0A2540" }}
      >
        {/* Crest icon */}
        <div
          className="flex items-center justify-center mb-4"
          style={{
            width: 72,
            height: 72,
            borderRadius: 18,
            background: "rgba(0,212,177,0.12)",
            border: "1.5px solid rgba(0,212,177,0.3)",
          }}
        >
          <svg width="38" height="38" viewBox="0 0 38 38" fill="none">
            <path d="M19 4L6 10V20C6 27.2 11.8 33.8 19 35.5C26.2 33.8 32 27.2 32 20V10L19 4Z" fill="#00D4B1" opacity="0.18"/>
            <path d="M19 4L6 10V20C6 27.2 11.8 33.8 19 35.5C26.2 33.8 32 27.2 32 20V10L19 4Z" stroke="#00D4B1" strokeWidth="1.8" strokeLinejoin="round"/>
            <path d="M13 19L17 23L25 15" stroke="#00D4B1" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"/>
            <circle cx="19" cy="19" r="4.5" fill="none" stroke="rgba(0,212,177,0.4)" strokeWidth="1"/>
          </svg>
        </div>
        <div className="text-center">
          <p className="text-xs font-medium tracking-widest uppercase mb-1" style={{ color: "#00D4B1", letterSpacing: "0.18em" }}>
            West Africa Examinations Council
          </p>
          <h1 className="text-2xl font-bold text-white tracking-tight">WAEC Direct</h1>
          <p className="text-sm mt-1" style={{ color: "rgba(255,255,255,0.45)" }}>
            Official Result Verification Portal
          </p>
        </div>
      </div>

      {/* Form card */}
      <div className="flex-1 flex flex-col px-6 pt-8 pb-6">
        <div
          className="rounded-2xl p-6"
          style={{ background: "#fff", border: "1px solid #E2E8F0", boxShadow: "0 2px 12px rgba(10,37,64,0.05)" }}
        >
          <h2 className="text-base font-semibold mb-1" style={{ color: "#0A2540" }}>Sign In to Your Account</h2>
          <p className="text-xs mb-6" style={{ color: "#94A3B8" }}>Enter your WAEC credentials to continue</p>

          {/* Index Number */}
          <label className="block mb-4">
            <span className="block text-xs font-semibold uppercase tracking-wider mb-2" style={{ color: "#0A2540", letterSpacing: "0.1em" }}>
              Candidate Index Number
            </span>
            <div
              className="flex items-center rounded-xl px-4 gap-3"
              style={{ border: "1.5px solid #E2E8F0", background: "#F8FAFC", height: 52 }}
            >
              <svg width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="#94A3B8" strokeWidth="1.5" strokeLinecap="round">
                <rect x="1.5" y="2.5" width="13" height="11" rx="2"/>
                <path d="M5 7h6M5 10h4"/>
              </svg>
              <input
                type="text"
                inputMode="numeric"
                pattern="\d{10}"
                maxLength={10}
                placeholder="0000000000"
                value={index}
                onChange={(e) => setIndex(e.target.value.replace(/\D/g, "").slice(0, 10))}
                className="flex-1 outline-none bg-transparent text-sm font-medium"
                style={{ color: "#0A2540", fontFamily: "JetBrains Mono", letterSpacing: "0.12em" }}
              />
              {index.length === 10 && (
                <svg width="14" height="14" viewBox="0 0 14 14" fill="none">
                  <circle cx="7" cy="7" r="6.5" fill="#00D4B1"/>
                  <path d="M4 7L6.2 9.2L10 5" stroke="white" strokeWidth="1.5" strokeLinecap="round"/>
                </svg>
              )}
            </div>
            <p className="text-xs mt-1.5" style={{ color: "#94A3B8" }}>{index.length}/10 digits</p>
          </label>

          {/* Password */}
          <label className="block mb-5">
            <span className="block text-xs font-semibold uppercase tracking-wider mb-2" style={{ color: "#0A2540", letterSpacing: "0.1em" }}>
              Password / PIN
            </span>
            <div
              className="flex items-center rounded-xl px-4 gap-3"
              style={{ border: "1.5px solid #E2E8F0", background: "#F8FAFC", height: 52 }}
            >
              <svg width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="#94A3B8" strokeWidth="1.5" strokeLinecap="round">
                <rect x="3" y="7" width="10" height="7.5" rx="2"/>
                <path d="M5.5 7V5a2.5 2.5 0 015 0v2"/>
                <circle cx="8" cy="10.5" r="1"/>
              </svg>
              <input
                type={pinVisible ? "text" : "password"}
                placeholder="Enter PIN or password"
                value={pin}
                onChange={(e) => setPin(e.target.value)}
                className="flex-1 outline-none bg-transparent text-sm"
                style={{ color: "#0A2540", fontFamily: "DM Sans" }}
              />
              <button onClick={() => setPinVisible(!pinVisible)} style={{ background: "none", border: "none", cursor: "pointer", padding: 0 }}>
                <svg width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="#94A3B8" strokeWidth="1.5" strokeLinecap="round">
                  {pinVisible ? (
                    <>
                      <path d="M2 8C2 8 4.5 3.5 8 3.5C11.5 3.5 14 8 14 8C14 8 11.5 12.5 8 12.5C4.5 12.5 2 8 2 8Z"/>
                      <circle cx="8" cy="8" r="2"/>
                    </>
                  ) : (
                    <>
                      <path d="M2 2l12 12M6.3 5.1A5 5 0 018 4.5c3.5 0 6 3.5 6 3.5s-.8 1.4-2.1 2.6M9.5 9.8A5 5 0 018 10c-3.5 0-6-2-6-2s.5-.9 1.5-1.9"/>
                    </>
                  )}
                </svg>
              </button>
            </div>
          </label>

          {error && (
            <div className="rounded-lg px-4 py-2.5 mb-4 flex items-center gap-2" style={{ background: "#FEF2F2", border: "1px solid #FECACA" }}>
              <svg width="14" height="14" viewBox="0 0 14 14" fill="none">
                <circle cx="7" cy="7" r="6.5" fill="#EF4444"/>
                <path d="M7 4v4M7 10v.5" stroke="white" strokeWidth="1.5" strokeLinecap="round"/>
              </svg>
              <span className="text-xs font-medium" style={{ color: "#EF4444" }}>{error}</span>
            </div>
          )}

          <button
            onClick={handleLogin}
            className="w-full rounded-xl font-semibold text-sm transition-all active:scale-95"
            style={{
              height: 52,
              background: "#0A2540",
              color: "#fff",
              border: "none",
              cursor: "pointer",
              letterSpacing: "0.02em",
              fontFamily: "DM Sans",
            }}
          >
            Log In
          </button>
        </div>

        {/* Biometrics */}
        <div className="flex flex-col items-center mt-6 gap-3">
          <button
            onClick={onLogin}
            className="flex items-center gap-3 rounded-xl px-6 py-3 transition-all"
            style={{ background: "#fff", border: "1px solid #E2E8F0", cursor: "pointer" }}
          >
            <svg width="22" height="22" viewBox="0 0 22 22" fill="none">
              <path d="M8 5.5C8 4.1 9.1 3 10.5 3C11.9 3 13 4.1 13 5.5C13 9 10.5 11 10.5 13" stroke="#0A2540" strokeWidth="1.5" strokeLinecap="round"/>
              <path d="M6 7.5C6 5 8 3 10.5 3C13 3 15 5 15 7.5V9C15 12.5 12.5 15 10.5 17.5" stroke="#00D4B1" strokeWidth="1.5" strokeLinecap="round"/>
              <path d="M4 10C4 6.7 6.9 4 10.5 4" stroke="#94A3B8" strokeWidth="1.5" strokeLinecap="round"/>
              <path d="M17 10C17 13 15 15.5 12.5 17.5" stroke="#94A3B8" strokeWidth="1.5" strokeLinecap="round"/>
            </svg>
            <span className="text-sm font-medium" style={{ color: "#0A2540" }}>Use Fingerprint / Face ID</span>
          </button>
          <p className="text-xs" style={{ color: "#94A3B8" }}>Biometric login requires prior password setup</p>
        </div>

        {/* Footer */}
        <div className="mt-auto pt-6 flex items-center justify-center gap-1">
          <svg width="12" height="12" viewBox="0 0 12 12" fill="none">
            <circle cx="6" cy="6" r="5.5" fill="none" stroke="#CBD5E1" strokeWidth="1"/>
            <path d="M4 6L6 8L8 4" stroke="#CBD5E1" strokeWidth="1.2" strokeLinecap="round"/>
          </svg>
          <span className="text-xs" style={{ color: "#CBD5E1" }}>256-bit TLS Encrypted · WAEC Certified</span>
        </div>
      </div>
    </div>
  );
}
