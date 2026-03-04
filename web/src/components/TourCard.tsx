'use client';

import Link from 'next/link';
import { TourListItem } from '@/lib/api';
import { StatusBadge } from './StatusBadge';
import { formatDate } from '@/lib/utils';
import { MapPin, Calendar, ChevronRight } from 'lucide-react';

interface TourCardProps {
  tour: TourListItem;
}

export function TourCard({ tour }: TourCardProps) {
  return (
    <Link href={`/tours/${tour.id}`}>
      <div className="card hover:shadow-md transition-shadow cursor-pointer group">
        <div className="flex justify-between items-start">
          <div className="space-y-2 flex-1">
            <div className="flex items-center gap-3">
              <h3 className="text-lg font-semibold text-gray-900 group-hover:text-primary-600 transition-colors">
                {tour.name}
              </h3>
              <StatusBadge status={tour.status} />
            </div>
            
            {tour.address && (
              <div className="flex items-center gap-1.5 text-gray-500 text-sm">
                <MapPin size={14} />
                <span>{tour.address}</span>
              </div>
            )}
            
            <div className="flex items-center gap-1.5 text-gray-400 text-xs">
              <Calendar size={12} />
              <span>Created {formatDate(tour.created_at)}</span>
            </div>
          </div>
          
          <ChevronRight
            size={20}
            className="text-gray-400 group-hover:text-primary-600 transition-colors mt-1"
          />
        </div>

        {tour.status === 'READY' && tour.pano_url && (
          <div className="mt-4 h-32 bg-gray-100 rounded-lg overflow-hidden">
            <img
              src={tour.pano_url}
              alt={tour.name}
              className="w-full h-full object-cover"
            />
          </div>
        )}
      </div>
    </Link>
  );
}
