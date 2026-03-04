'use client';

import { useEffect, useState, useCallback } from 'react';
import { useRouter, useParams } from 'next/navigation';
import Link from 'next/link';
import { useAuth } from '@/lib/auth-context';
import { api, Tour } from '@/lib/api';
import { Navbar, StatusBadge, QRCodeDisplay, PanoramaViewer } from '@/components';
import { formatDate, copyToClipboard, generateEmbedCode } from '@/lib/utils';
import {
  MapPin,
  Calendar,
  Link2,
  Code,
  Download,
  Copy,
  Check,
  Smartphone,
  RefreshCw,
  Trash2,
  ExternalLink,
} from 'lucide-react';

export default function TourDetailPage() {
  const router = useRouter();
  const params = useParams();
  const tourId = params.id as string;
  const { token, user, loading: authLoading } = useAuth();
  
  const [tour, setTour] = useState<Tour | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState('');
  const [copied, setCopied] = useState<string | null>(null);
  const [deleting, setDeleting] = useState(false);

  const loadTour = useCallback(async () => {
    if (!tourId) return;
    
    try {
      const data = await api.getTour(tourId, token || undefined);
      setTour(data);
    } catch (err: any) {
      setError(err.message || 'Failed to load tour');
    } finally {
      setLoading(false);
    }
  }, [tourId, token]);

  useEffect(() => {
    if (!authLoading) {
      loadTour();
    }
  }, [authLoading, loadTour]);

  useEffect(() => {
    // Poll for status updates if processing
    if (tour && (tour.status === 'UPLOADING' || tour.status === 'PROCESSING')) {
      const interval = setInterval(loadTour, 3000);
      return () => clearInterval(interval);
    }
  }, [tour, loadTour]);

  const handleCopy = async (text: string, type: string) => {
    try {
      await copyToClipboard(text);
      setCopied(type);
      setTimeout(() => setCopied(null), 2000);
    } catch (err) {
      console.error('Failed to copy:', err);
    }
  };

  const handleDelete = async () => {
    if (!tour || !token) return;
    
    if (!confirm('Are you sure you want to delete this tour? This action cannot be undone.')) {
      return;
    }

    setDeleting(true);
    try {
      await api.deleteTour(tour.id, token);
      router.push('/dashboard');
    } catch (err: any) {
      setError(err.message || 'Failed to delete tour');
      setDeleting(false);
    }
  };

  if (authLoading || loading) {
    return (
      <div className="min-h-screen bg-gray-50">
        <Navbar />
        <div className="flex items-center justify-center py-20">
          <div className="animate-spin rounded-full h-8 w-8 border-b-2 border-primary-600"></div>
        </div>
      </div>
    );
  }

  if (error || !tour) {
    return (
      <div className="min-h-screen bg-gray-50">
        <Navbar />
        <div className="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 py-8">
          <div className="p-6 bg-red-50 border border-red-200 rounded-lg text-red-700">
            {error || 'Tour not found'}
          </div>
        </div>
      </div>
    );
  }

  const publicUrl = tour.public_viewer_url;
  const embedCode = generateEmbedCode(publicUrl);

  return (
    <div className="min-h-screen bg-gray-50">
      <Navbar />
      
      <main className="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 py-8">
        {/* Header */}
        <div className="flex flex-col md:flex-row md:items-start md:justify-between gap-4 mb-8">
          <div>
            <div className="flex items-center gap-3 mb-2">
              <h1 className="text-2xl font-bold text-gray-900">{tour.name}</h1>
              <StatusBadge status={tour.status} />
            </div>
            
            {tour.address && (
              <div className="flex items-center gap-1.5 text-gray-600 mb-1">
                <MapPin size={16} />
                <span>{tour.address}</span>
              </div>
            )}
            
            <div className="flex items-center gap-1.5 text-gray-500 text-sm">
              <Calendar size={14} />
              <span>Created {formatDate(tour.created_at)}</span>
            </div>
          </div>

          <div className="flex items-center gap-2">
            <button
              onClick={loadTour}
              className="btn btn-secondary flex items-center gap-2"
              title="Refresh"
            >
              <RefreshCw size={16} />
            </button>
            {user && (
              <button
                onClick={handleDelete}
                disabled={deleting}
                className="btn btn-secondary text-red-600 hover:bg-red-50 flex items-center gap-2"
              >
                <Trash2 size={16} />
                <span className="hidden md:inline">Delete</span>
              </button>
            )}
          </div>
        </div>

        <div className="grid lg:grid-cols-3 gap-8">
          {/* Main Content */}
          <div className="lg:col-span-2 space-y-6">
            {/* Viewer or Status */}
            {tour.status === 'READY' && tour.pano_url ? (
              <div className="card p-0 overflow-hidden">
                <div className="aspect-[16/9]">
                  <PanoramaViewer imageUrl={tour.pano_url} />
                </div>
              </div>
            ) : tour.status === 'WAITING' ? (
              <div className="card text-center py-12">
                <div className="w-20 h-20 bg-yellow-100 rounded-full flex items-center justify-center mx-auto mb-6">
                  <Smartphone size={40} className="text-yellow-600" />
                </div>
                <h2 className="text-xl font-semibold text-gray-900 mb-2">
                  Waiting for Capture
                </h2>
                <p className="text-gray-600 max-w-md mx-auto">
                  Scan the QR code on the right with the Realtor 360 iOS app
                  to start capturing photos for this tour.
                </p>
              </div>
            ) : tour.status === 'UPLOADING' || tour.status === 'PROCESSING' ? (
              <div className="card text-center py-12">
                <div className="w-20 h-20 bg-primary-100 rounded-full flex items-center justify-center mx-auto mb-6">
                  <svg className="animate-spin h-10 w-10 text-primary-600" viewBox="0 0 24 24">
                    <circle
                      className="opacity-25"
                      cx="12"
                      cy="12"
                      r="10"
                      stroke="currentColor"
                      strokeWidth="4"
                      fill="none"
                    />
                    <path
                      className="opacity-75"
                      fill="currentColor"
                      d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4zm2 5.291A7.962 7.962 0 014 12H0c0 3.042 1.135 5.824 3 7.938l3-2.647z"
                    />
                  </svg>
                </div>
                <h2 className="text-xl font-semibold text-gray-900 mb-2">
                  {tour.status === 'UPLOADING' ? 'Uploading Photos' : 'Processing Panorama'}
                </h2>
                <p className="text-gray-600">
                  {tour.status === 'UPLOADING'
                    ? 'Photos are being uploaded...'
                    : 'Stitching photos into a 360° panorama...'}
                </p>
              </div>
            ) : tour.status === 'FAILED' ? (
              <div className="card text-center py-12">
                <div className="w-20 h-20 bg-red-100 rounded-full flex items-center justify-center mx-auto mb-6">
                  <span className="text-4xl">⚠️</span>
                </div>
                <h2 className="text-xl font-semibold text-gray-900 mb-2">
                  Processing Failed
                </h2>
                <p className="text-gray-600">
                  There was an error processing your photos. Please try capturing again.
                </p>
              </div>
            ) : null}

            {/* Share Options (when ready) */}
            {tour.status === 'READY' && (
              <div className="card space-y-4">
                <h2 className="font-semibold text-gray-900">Share & Embed</h2>
                
                {/* Share Link */}
                <div>
                  <label className="block text-sm font-medium text-gray-700 mb-2">
                    <Link2 size={14} className="inline mr-1.5" />
                    Public Link
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
                      <span>{copied === 'link' ? 'Copied!' : 'Copy'}</span>
                    </button>
                    <a
                      href={publicUrl}
                      target="_blank"
                      rel="noopener noreferrer"
                      className="btn btn-secondary"
                    >
                      <ExternalLink size={16} />
                    </a>
                  </div>
                </div>

                {/* Embed Code */}
                <div>
                  <label className="block text-sm font-medium text-gray-700 mb-2">
                    <Code size={14} className="inline mr-1.5" />
                    Embed Code
                  </label>
                  <div className="flex gap-2">
                    <textarea
                      value={embedCode}
                      readOnly
                      rows={2}
                      className="input flex-1 text-sm bg-gray-50 font-mono"
                    />
                    <button
                      onClick={() => handleCopy(embedCode, 'embed')}
                      className="btn btn-secondary self-start flex items-center gap-2"
                    >
                      {copied === 'embed' ? <Check size={16} /> : <Copy size={16} />}
                      <span>{copied === 'embed' ? 'Copied!' : 'Copy'}</span>
                    </button>
                  </div>
                </div>

                {/* Download */}
                <div>
                  <label className="block text-sm font-medium text-gray-700 mb-2">
                    <Download size={14} className="inline mr-1.5" />
                    Download
                  </label>
                  <a
                    href={`/api/tours/${tour.id}/download`}
                    className="btn btn-outline inline-flex items-center gap-2"
                  >
                    <Download size={16} />
                    Download Panorama (JPG)
                  </a>
                </div>
              </div>
            )}
          </div>

          {/* Sidebar - QR Code */}
          <div className="space-y-6">
            {tour.status === 'WAITING' && (
              <div className="card text-center">
                <h2 className="font-semibold text-gray-900 mb-4">
                  Scan to Capture
                </h2>
                <div className="flex justify-center mb-4">
                  <QRCodeDisplay value={tour.qr_data} size={200} />
                </div>
                <p className="text-sm text-gray-600 mb-4">
                  Scan this QR code with the Realtor 360 iOS app to start capturing.
                </p>
                <div className="text-xs text-gray-400 break-all">
                  {tour.capture_universal_link}
                </div>
              </div>
            )}

            {/* Tour Info */}
            <div className="card">
              <h2 className="font-semibold text-gray-900 mb-4">Tour Info</h2>
              <dl className="space-y-3 text-sm">
                <div>
                  <dt className="text-gray-500">Status</dt>
                  <dd className="font-medium"><StatusBadge status={tour.status} /></dd>
                </div>
                <div>
                  <dt className="text-gray-500">Tour ID</dt>
                  <dd className="font-mono text-xs break-all">{tour.id}</dd>
                </div>
                <div>
                  <dt className="text-gray-500">Public Slug</dt>
                  <dd className="font-mono">{tour.public_slug}</dd>
                </div>
                {tour.completed_at && (
                  <div>
                    <dt className="text-gray-500">Completed</dt>
                    <dd>{formatDate(tour.completed_at)}</dd>
                  </div>
                )}
                {tour.notes && (
                  <div>
                    <dt className="text-gray-500">Notes</dt>
                    <dd className="whitespace-pre-wrap">{tour.notes}</dd>
                  </div>
                )}
              </dl>
            </div>
          </div>
        </div>
      </main>
    </div>
  );
}
