import { clsx, type ClassValue } from 'clsx';
import { twMerge } from 'tailwind-merge';
import { TourStatus } from './api';

export function cn(...inputs: ClassValue[]) {
  return twMerge(clsx(inputs));
}

export function formatDate(dateString: string): string {
  const date = new Date(dateString);
  return date.toLocaleDateString('en-US', {
    year: 'numeric',
    month: 'short',
    day: 'numeric',
    hour: '2-digit',
    minute: '2-digit',
  });
}

export function getStatusColor(status: TourStatus): string {
  switch (status) {
    case 'WAITING':
      return 'status-waiting';
    case 'UPLOADING':
      return 'status-uploading';
    case 'PROCESSING':
      return 'status-processing';
    case 'READY':
      return 'status-ready';
    case 'FAILED':
      return 'status-failed';
    default:
      return 'bg-gray-100 text-gray-800';
  }
}

export function getStatusLabel(status: TourStatus): string {
  switch (status) {
    case 'WAITING':
      return 'Waiting for Capture';
    case 'UPLOADING':
      return 'Uploading';
    case 'PROCESSING':
      return 'Processing';
    case 'READY':
      return 'Ready';
    case 'FAILED':
      return 'Failed';
    default:
      return status;
  }
}

export function copyToClipboard(text: string): Promise<void> {
  return navigator.clipboard.writeText(text);
}

export function generateEmbedCode(publicUrl: string, width = 800, height = 450): string {
  return `<iframe src="${publicUrl}" width="${width}" height="${height}" frameborder="0" allowfullscreen allow="fullscreen; xr-spatial-tracking"></iframe>`;
}
