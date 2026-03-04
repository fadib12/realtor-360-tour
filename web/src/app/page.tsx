'use client';

import Link from 'next/link';
import { useAuth } from '@/lib/auth-context';
import { useRouter } from 'next/navigation';
import { useEffect } from 'react';
import { Camera, Share2, Globe, ArrowRight } from 'lucide-react';

export default function HomePage() {
  const { user, loading } = useAuth();
  const router = useRouter();

  useEffect(() => {
    if (!loading && user) {
      router.push('/dashboard');
    }
  }, [user, loading, router]);

  if (loading) {
    return (
      <div className="min-h-screen flex items-center justify-center">
        <div className="animate-spin rounded-full h-8 w-8 border-b-2 border-primary-600"></div>
      </div>
    );
  }

  return (
    <div className="min-h-screen">
      {/* Hero */}
      <div className="bg-gradient-to-br from-primary-600 to-primary-800 text-white">
        <nav className="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 py-6">
          <div className="flex justify-between items-center">
            <div className="flex items-center gap-2">
              <div className="w-10 h-10 bg-white/20 backdrop-blur rounded-lg flex items-center justify-center">
                <span className="text-white font-bold">360</span>
              </div>
              <span className="font-semibold text-xl">Realtor 360</span>
            </div>
            <div className="flex items-center gap-4">
              <Link href="/login" className="text-white/80 hover:text-white">
                Login
              </Link>
              <Link
                href="/register"
                className="bg-white text-primary-600 px-4 py-2 rounded-lg font-medium hover:bg-gray-100 transition"
              >
                Get Started
              </Link>
            </div>
          </div>
        </nav>

        <div className="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 py-24 text-center">
          <h1 className="text-5xl font-bold mb-6">
            Create Stunning 360° Tours
            <br />
            <span className="text-primary-200">In Under a Minute</span>
          </h1>
          <p className="text-xl text-primary-100 mb-8 max-w-2xl mx-auto">
            Capture immersive virtual tours with your iPhone, automatically stitch
            them into professional 360° panoramas, and share with anyone, anywhere.
          </p>
          <Link
            href="/register"
            className="inline-flex items-center gap-2 bg-white text-primary-600 px-8 py-4 rounded-xl font-semibold text-lg hover:bg-gray-100 transition shadow-lg"
          >
            Start Creating Tours
            <ArrowRight size={20} />
          </Link>
        </div>
      </div>

      {/* Features */}
      <div className="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 py-24">
        <h2 className="text-3xl font-bold text-center mb-16">How It Works</h2>
        
        <div className="grid md:grid-cols-3 gap-12">
          <div className="text-center">
            <div className="w-16 h-16 bg-primary-100 rounded-2xl flex items-center justify-center mx-auto mb-6">
              <Camera className="w-8 h-8 text-primary-600" />
            </div>
            <h3 className="text-xl font-semibold mb-3">1. Guided Capture</h3>
            <p className="text-gray-600">
              Our iOS app guides you through 16 shots with visual targets.
              Just follow the dots and the app captures automatically.
            </p>
          </div>
          
          <div className="text-center">
            <div className="w-16 h-16 bg-primary-100 rounded-2xl flex items-center justify-center mx-auto mb-6">
              <Globe className="w-8 h-8 text-primary-600" />
            </div>
            <h3 className="text-xl font-semibold mb-3">2. Auto Stitching</h3>
            <p className="text-gray-600">
              Photos are uploaded and automatically stitched into a seamless
              equirectangular panorama on our servers.
            </p>
          </div>
          
          <div className="text-center">
            <div className="w-16 h-16 bg-primary-100 rounded-2xl flex items-center justify-center mx-auto mb-6">
              <Share2 className="w-8 h-8 text-primary-600" />
            </div>
            <h3 className="text-xl font-semibold mb-3">3. Share Anywhere</h3>
            <p className="text-gray-600">
              Get a shareable link and embed code. Your clients can explore
              the property in immersive 360° from any device.
            </p>
          </div>
        </div>
      </div>

      {/* CTA */}
      <div className="bg-gray-50">
        <div className="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 py-16 text-center">
          <h2 className="text-2xl font-bold mb-4">Ready to create your first tour?</h2>
          <p className="text-gray-600 mb-8">
            Join thousands of realtors using Realtor 360 to showcase properties.
          </p>
          <Link
            href="/register"
            className="btn btn-primary inline-flex items-center gap-2"
          >
            Get Started Free
            <ArrowRight size={16} />
          </Link>
        </div>
      </div>

      {/* Footer */}
      <footer className="bg-gray-900 text-gray-400 py-12">
        <div className="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8 text-center">
          <div className="flex items-center justify-center gap-2 mb-4">
            <div className="w-8 h-8 bg-white/10 rounded-lg flex items-center justify-center">
              <span className="text-white font-bold text-sm">360</span>
            </div>
            <span className="font-semibold text-white">Realtor 360</span>
          </div>
          <p className="text-sm">
            © {new Date().getFullYear()} Realtor 360. All rights reserved.
          </p>
        </div>
      </footer>
    </div>
  );
}
