'use client';

import { useEffect, useState } from 'react';
import { useParams } from 'next/navigation';
import Link from 'next/link';
import { api, PublicTour } from '@/lib/api';
import { PanoramaViewer } from '@/components';
import { copyToClipboard, generateEmbedCode } from '@/lib/utils';
import { MapPin, Link2, Code, Download, Copy, Check, Share2, X } from 'lucide-react';

export default function PublicViewerPage() {
  const params = useParams();
  const slug = params.slug as string;
  
  const [tour, setTour] = useState<PublicTour | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState('');
  const [showShare, setShowShare] = useState(false);
  const [copied, setCopied] = useState<string | null>(null);

  useEffect(() => {
    if (slug) {
      loadTour();
    }
  }, [slug]);

  const loadTour = async () => {
    try {
      const data = await api.getPublicTour(slug);
      setTour(data);
    } catch (err: any) {
      setError(err.message || 'Tour not found');
    } finally {
      setLoading(false);
    }
  };

  const handleCopy = async (text: string, type: string) => {
    try {
      await copyToClipboard(text);
      setCopied(type);
      setTimeout(() => setCopied(null), 2000);
    } catch (err) {
      console.error('Failed to copy:', err);
    }
  };

  if (loading) {
    return (
      <div className="min-h-screen bg-gray-900 flex items-center justify-center">
        <div className="animate-spin rounded-full h-8 w-8 border-b-2 border-white"></div>
      </div>
    );
  }

  if (error || !tour || !tour.pano_url) {
    return (
      <div className="min-h-screen bg-gray-900 flex items-center justify-center">
        <div className="text-center">
          <h1 className="text-2xl font-bold text-white mb-4">Tour Not Found</h1>
          <p className="text-gray-400 mb-6">{error || 'This tour may not exist or is not ready yet.'}</p>
          <Link href="/" className="btn btn-primary">
            Go Home
          </Link>
        </div>
      </div>
    );
  }

  const publicUrl = typeof window !== 'undefined' ? window.location.href : '';
  const embedCode = generateEmbedCode(publicUrl);

  return (
    <div className="min-h-screen bg-gray-900 relative">
      {/* Full screen panorama viewer */}
      <div className="fixed inset-0">
        <PanoramaViewer
          imageUrl={tour.pano_url}
          autoRotate={-2}
          className="w-full h-full rounded-none"
        />
      </div>

      {/* Header overlay */}
      <div className="fixed top-0 left-0 right-0 z-10 bg-gradient-to-b from-black/60 to-transparent">
        <div className="max-w-7xl mx-auto px-4 py-4 flex justify-between items-center">
          <div className="text-white">
            <h1 className="font-semibold text-lg">{tour.name}</h1>
            {tour.address && (
              <div className="flex items-center gap-1.5 text-white/70 text-sm">
                <MapPin size={14} />
                <span>{tour.address}</span>
              </div>
            )}
          </div>

          <div className="flex items-center gap-2">
            <button
              onClick={() => setShowShare(true)}
              className="bg-white/20 backdrop-blur hover:bg-white/30 text-white px-4 py-2 rounded-lg flex items-center gap-2 transition"
            >
              <Share2 size={16} />
              <span className="hidden sm:inline">Share</span>
            </button>
            <a
              href={`/api/tours/${tour.id}/download`}
              className="bg-white/20 backdrop-blur hover:bg-white/30 text-white px-4 py-2 rounded-lg flex items-center gap-2 transition"
            >
              <Download size={16} />
              <span className="hidden sm:inline">Download</span>
            </a>
          </div>
        </div>
      </div>

      {/* Branding footer */}
      <div className="fixed bottom-0 left-0 right-0 z-10 bg-gradient-to-t from-black/60 to-transparent">
        <div className="max-w-7xl mx-auto px-4 py-4 flex justify-between items-center">
          <Link href="/" className="flex items-center gap-2 text-white/70 hover:text-white transition">
            <div className="w-6 h-6 bg-white/20 rounded flex items-center justify-center">
              <span className="text-white font-bold text-xs">360</span>
            </div>
            <span className="text-sm">Powered by Realtor 360</span>
          </Link>
          <div className="text-white/50 text-xs">
            Drag to look around
          </div>
        </div>
      </div>

      {/* Share Modal */}
      {showShare && (
        <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/70 p-4">
          <div className="bg-white rounded-xl max-w-md w-full p-6 relative">
            <button
              onClick={() => setShowShare(false)}
              className="absolute right-4 top-4 text-gray-400 hover:text-gray-600"
            >
              <X size={20} />
            </button>

            <h2 className="text-xl font-semibold text-gray-900 mb-6">Share Tour</h2>

            {/* Share Link */}
            <div className="mb-4">
              <label className="block text-sm font-medium text-gray-700 mb-2">
                <Link2 size={14} className="inline mr-1.5" />
                Link
              </label>
              <div className="flex gap-2">
                <input
                  type="text"
                  value={publicUrl}
                  readOnly
                  className="input flex-1 text-sm bg-gray-50"
                />
                <button
                  onClick={() => handleCopy(publicUrl, 'link')}
                  className="btn btn-secondary flex items-center gap-2"
                >
                  {copied === 'link' ? <Check size={16} /> : <Copy size={16} />}
                </button>
              </div>
            </div>

            {/* Embed Code */}
            <div className="mb-6">
              <label className="block text-sm font-medium text-gray-700 mb-2">
                <Code size={14} className="inline mr-1.5" />
                Embed Code
              </label>
              <div className="flex gap-2">
                <textarea
                  value={embedCode}
                  readOnly
                  rows={3}
                  className="input flex-1 text-xs bg-gray-50 font-mono"
                />
                <button
                  onClick={() => handleCopy(embedCode, 'embed')}
                  className="btn btn-secondary self-start flex items-center gap-2"
                >
                  {copied === 'embed' ? <Check size={16} /> : <Copy size={16} />}
                </button>
              </div>
            </div>

            <button
              onClick={() => setShowShare(false)}
              className="btn btn-primary w-full"
            >
              Done
            </button>
          </div>
        </div>
      )}
    </div>
  );
}
