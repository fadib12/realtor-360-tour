'use client';

import { useState } from 'react';
import { useRouter } from 'next/navigation';
import { useAuth } from '@/lib/auth-context';
import { api } from '@/lib/api';
import { Navbar } from '@/components';
import { MapPin, FileText, Home, AlertCircle } from 'lucide-react';

export default function NewTourPage() {
  const router = useRouter();
  const { token, user, loading: authLoading } = useAuth();
  const [name, setName] = useState('');
  const [address, setAddress] = useState('');
  const [notes, setNotes] = useState('');
  const [error, setError] = useState('');
  const [loading, setLoading] = useState(false);

  if (authLoading) {
    return (
      <div className="min-h-screen flex items-center justify-center">
        <div className="animate-spin rounded-full h-8 w-8 border-b-2 border-primary-600"></div>
      </div>
    );
  }

  if (!user) {
    router.push('/login');
    return null;
  }

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    setError('');

    if (!name.trim()) {
      setError('Tour name is required');
      return;
    }

    if (!token) {
      setError('Not authenticated');
      return;
    }

    setLoading(true);

    try {
      const tour = await api.createTour(token, {
        name: name.trim(),
        address: address.trim() || undefined,
        notes: notes.trim() || undefined,
      });
      router.push(`/tours/${tour.id}`);
    } catch (err: any) {
      setError(err.message || 'Failed to create tour');
    } finally {
      setLoading(false);
    }
  };

  return (
    <div className="min-h-screen bg-gray-50">
      <Navbar />
      
      <main className="max-w-2xl mx-auto px-4 sm:px-6 lg:px-8 py-8">
        <div className="mb-8">
          <h1 className="text-2xl font-bold text-gray-900">Create New Tour</h1>
          <p className="text-gray-600 mt-1">
            Enter details for your 360° virtual tour
          </p>
        </div>

        <div className="card">
          {error && (
            <div className="mb-6 p-3 bg-red-50 border border-red-200 rounded-lg flex items-center gap-2 text-red-700">
              <AlertCircle size={18} />
              <span className="text-sm">{error}</span>
            </div>
          )}

          <form onSubmit={handleSubmit} className="space-y-6">
            <div>
              <label htmlFor="name" className="block text-sm font-medium text-gray-700 mb-1">
                Tour Name <span className="text-red-500">*</span>
              </label>
              <div className="relative">
                <Home
                  size={18}
                  className="absolute left-3 top-1/2 -translate-y-1/2 text-gray-400"
                />
                <input
                  id="name"
                  type="text"
                  value={name}
                  onChange={(e) => setName(e.target.value)}
                  className="input pl-10"
                  placeholder="e.g., 123 Main Street - Living Room"
                  required
                />
              </div>
              <p className="mt-1 text-xs text-gray-500">
                Give your tour a descriptive name
              </p>
            </div>

            <div>
              <label htmlFor="address" className="block text-sm font-medium text-gray-700 mb-1">
                Address (optional)
              </label>
              <div className="relative">
                <MapPin
                  size={18}
                  className="absolute left-3 top-1/2 -translate-y-1/2 text-gray-400"
                />
                <input
                  id="address"
                  type="text"
                  value={address}
                  onChange={(e) => setAddress(e.target.value)}
                  className="input pl-10"
                  placeholder="e.g., 123 Main Street, City, State"
                />
              </div>
            </div>

            <div>
              <label htmlFor="notes" className="block text-sm font-medium text-gray-700 mb-1">
                Notes (optional)
              </label>
              <div className="relative">
                <FileText
                  size={18}
                  className="absolute left-3 top-3 text-gray-400"
                />
                <textarea
                  id="notes"
                  value={notes}
                  onChange={(e) => setNotes(e.target.value)}
                  className="input pl-10 min-h-[100px]"
                  placeholder="Any additional notes about this tour..."
                />
              </div>
            </div>

            <div className="flex gap-4 pt-4">
              <button
                type="button"
                onClick={() => router.back()}
                className="btn btn-secondary flex-1"
              >
                Cancel
              </button>
              <button
                type="submit"
                disabled={loading}
                className="btn btn-primary flex-1 flex items-center justify-center"
              >
                {loading ? (
                  <svg className="animate-spin h-5 w-5" viewBox="0 0 24 24">
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
                ) : (
                  'Create Tour'
                )}
              </button>
            </div>
          </form>
        </div>

        <div className="mt-6 p-4 bg-blue-50 border border-blue-200 rounded-lg">
          <h3 className="font-medium text-blue-900 mb-2">What happens next?</h3>
          <ol className="text-sm text-blue-700 space-y-1 list-decimal list-inside">
            <li>You'll see a QR code for your tour</li>
            <li>Scan the QR code with the Realtor 360 iOS app</li>
            <li>Follow the guided capture to take 16 photos</li>
            <li>Photos will be automatically stitched into a 360° panorama</li>
          </ol>
        </div>
      </main>
    </div>
  );
}
