'use client';

import Link from 'next/link';
import { useAuth } from '@/lib/auth-context';
import { Home, LogOut, Plus, User } from 'lucide-react';

export function Navbar() {
  const { user, logout } = useAuth();

  return (
    <nav className="bg-white border-b border-gray-200 sticky top-0 z-50">
      <div className="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8">
        <div className="flex justify-between items-center h-16">
          <div className="flex items-center gap-8">
            <Link href="/dashboard" className="flex items-center gap-2">
              <div className="w-8 h-8 bg-primary-600 rounded-lg flex items-center justify-center">
                <span className="text-white font-bold text-sm">360</span>
              </div>
              <span className="font-semibold text-gray-900">Realtor 360</span>
            </Link>
            
            {user && (
              <div className="hidden md:flex items-center gap-6">
                <Link
                  href="/dashboard"
                  className="text-gray-600 hover:text-gray-900 flex items-center gap-1.5"
                >
                  <Home size={18} />
                  <span>Dashboard</span>
                </Link>
                <Link
                  href="/tours/new"
                  className="text-gray-600 hover:text-gray-900 flex items-center gap-1.5"
                >
                  <Plus size={18} />
                  <span>New Tour</span>
                </Link>
              </div>
            )}
          </div>

          <div className="flex items-center gap-4">
            {user ? (
              <>
                <div className="hidden md:flex items-center gap-2 text-sm text-gray-600">
                  <User size={16} />
                  <span>{user.name || user.email}</span>
                </div>
                <button
                  onClick={logout}
                  className="btn btn-secondary flex items-center gap-2"
                >
                  <LogOut size={16} />
                  <span className="hidden md:inline">Logout</span>
                </button>
              </>
            ) : (
              <Link href="/login" className="btn btn-primary">
                Login
              </Link>
            )}
          </div>
        </div>
      </div>
    </nav>
  );
}
