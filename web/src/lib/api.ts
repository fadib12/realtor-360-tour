const API_URL = process.env.NEXT_PUBLIC_API_URL || 'http://localhost:8000';

interface FetchOptions extends RequestInit {
  token?: string;
}

export async function apiClient<T>(
  endpoint: string,
  options: FetchOptions = {}
): Promise<T> {
  const { token, ...fetchOptions } = options;
  
  const headers: HeadersInit = {
    'Content-Type': 'application/json',
    ...fetchOptions.headers,
  };
  
  if (token) {
    (headers as Record<string, string>)['Authorization'] = `Bearer ${token}`;
  }
  
  const response = await fetch(`${API_URL}${endpoint}`, {
    ...fetchOptions,
    headers,
  });
  
  if (!response.ok) {
    const error = await response.json().catch(() => ({ detail: 'Request failed' }));
    throw new Error(error.detail || 'Request failed');
  }
  
  return response.json();
}

// Tour types
export type TourStatus = 'WAITING' | 'UPLOADING' | 'PROCESSING' | 'READY' | 'FAILED';

export interface Tour {
  id: string;
  name: string;
  address?: string;
  notes?: string;
  status: TourStatus;
  public_slug: string;
  pano_url?: string;
  created_at: string;
  completed_at?: string;
  web_url: string;
  public_viewer_url: string;
  capture_universal_link: string;
  qr_data: string;
  qr_svg?: string;
}

export interface TourListItem {
  id: string;
  name: string;
  address?: string;
  status: TourStatus;
  public_slug: string;
  pano_url?: string;
  created_at: string;
  completed_at?: string;
}

export interface PublicTour {
  id: string;
  name: string;
  address?: string;
  status: TourStatus;
  pano_url?: string;
  public_slug: string;
}

// Auth types
export interface User {
  id: string;
  email: string;
  name?: string;
  created_at: string;
}

export interface AuthResponse {
  access_token: string;
  token_type: string;
  user: User;
}

// API functions
export const api = {
  // Auth
  async register(email: string, password: string, name?: string): Promise<AuthResponse> {
    return apiClient<AuthResponse>('/api/auth/register', {
      method: 'POST',
      body: JSON.stringify({ email, password, name }),
    });
  },
  
  async login(email: string, password: string): Promise<AuthResponse> {
    const formData = new URLSearchParams();
    formData.append('username', email);
    formData.append('password', password);
    
    const response = await fetch(`${API_URL}/api/auth/login`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/x-www-form-urlencoded',
      },
      body: formData,
    });
    
    if (!response.ok) {
      const error = await response.json().catch(() => ({ detail: 'Login failed' }));
      throw new Error(error.detail || 'Login failed');
    }
    
    return response.json();
  },
  
  async getMe(token: string): Promise<User> {
    return apiClient<User>('/api/auth/me', { token });
  },
  
  // Tours
  async createTour(token: string, data: { name: string; address?: string; notes?: string }): Promise<Tour> {
    return apiClient<Tour>('/api/tours', {
      method: 'POST',
      token,
      body: JSON.stringify(data),
    });
  },
  
  async listTours(token: string): Promise<TourListItem[]> {
    return apiClient<TourListItem[]>('/api/tours', { token });
  },
  
  async getTour(tourId: string, token?: string): Promise<Tour> {
    return apiClient<Tour>(`/api/tours/${tourId}`, { token });
  },
  
  async getPublicTour(slug: string): Promise<PublicTour> {
    return apiClient<PublicTour>(`/api/tours/public/${slug}`);
  },
  
  async deleteTour(tourId: string, token: string): Promise<void> {
    return apiClient<void>(`/api/tours/${tourId}`, {
      method: 'DELETE',
      token,
    });
  },
};
