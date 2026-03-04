'use client';

import { QRCodeSVG } from 'qrcode.react';

interface QRCodeDisplayProps {
  value: string;
  size?: number;
  className?: string;
}

export function QRCodeDisplay({ value, size = 200, className = '' }: QRCodeDisplayProps) {
  return (
    <div className={`bg-white p-4 rounded-lg inline-block ${className}`}>
      <QRCodeSVG
        value={value}
        size={size}
        bgColor="#ffffff"
        fgColor="#000000"
        level="M"
        includeMargin={false}
      />
    </div>
  );
}
