'use client';

import { useEffect, useRef } from 'react';

interface PanoramaViewerProps {
  imageUrl: string;
  className?: string;
  autoLoad?: boolean;
  autoRotate?: number;
  showControls?: boolean;
}

export function PanoramaViewer({
  imageUrl,
  className = '',
  autoLoad = true,
  autoRotate = 0,
  showControls = true,
}: PanoramaViewerProps) {
  const containerRef = useRef<HTMLDivElement>(null);
  const viewerRef = useRef<any>(null);

  useEffect(() => {
    if (!containerRef.current || !imageUrl) return;

    // Dynamically load Pannellum
    const loadPannellum = async () => {
      // Load Pannellum CSS
      if (!document.querySelector('link[href*="pannellum"]')) {
        const link = document.createElement('link');
        link.rel = 'stylesheet';
        link.href = 'https://cdn.jsdelivr.net/npm/pannellum@2.5.6/build/pannellum.css';
        document.head.appendChild(link);
      }

      // Load Pannellum JS
      if (!window.pannellum) {
        await new Promise<void>((resolve, reject) => {
          const script = document.createElement('script');
          script.src = 'https://cdn.jsdelivr.net/npm/pannellum@2.5.6/build/pannellum.js';
          script.onload = () => resolve();
          script.onerror = reject;
          document.head.appendChild(script);
        });
      }

      // Initialize viewer
      if (containerRef.current && window.pannellum) {
        viewerRef.current = window.pannellum.viewer(containerRef.current, {
          type: 'equirectangular',
          panorama: imageUrl,
          autoLoad: autoLoad,
          autoRotate: autoRotate,
          showControls: showControls,
          compass: false,
          mouseZoom: true,
          draggable: true,
          friction: 0.15,
          hfov: 100,
          minHfov: 50,
          maxHfov: 120,
        });
      }
    };

    loadPannellum();

    return () => {
      if (viewerRef.current && typeof viewerRef.current.destroy === 'function') {
        viewerRef.current.destroy();
      }
    };
  }, [imageUrl, autoLoad, autoRotate, showControls]);

  return (
    <div
      ref={containerRef}
      className={`w-full h-full min-h-[400px] bg-gray-900 rounded-lg overflow-hidden ${className}`}
    />
  );
}

// Add pannellum to window type
declare global {
  interface Window {
    pannellum: any;
  }
}
