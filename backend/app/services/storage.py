import boto3
from botocore.config import Config
from typing import Optional
from app.config import get_settings

settings = get_settings()


class StorageService:
    def __init__(self):
        client_config = Config(
            signature_version='s3v4',
            s3={'addressing_style': 'path'}
        )
        
        self.s3 = boto3.client(
            's3',
            region_name=settings.s3_region,
            endpoint_url=settings.s3_endpoint_url if settings.s3_endpoint_url else None,
            aws_access_key_id=settings.aws_access_key_id,
            aws_secret_access_key=settings.aws_secret_access_key,
            config=client_config
        )
        self.bucket = settings.s3_bucket
    
    def generate_presigned_upload_url(self, key: str, expires_in: int = 3600) -> str:
        """Generate a presigned URL for uploading a file"""
        url = self.s3.generate_presigned_url(
            'put_object',
            Params={
                'Bucket': self.bucket,
                'Key': key,
                'ContentType': 'image/jpeg'
            },
            ExpiresIn=expires_in
        )
        return url
    
    def generate_presigned_download_url(
        self, 
        key: str, 
        expires_in: int = 3600,
        filename: Optional[str] = None
    ) -> str:
        """Generate a presigned URL for downloading a file"""
        params = {
            'Bucket': self.bucket,
            'Key': key,
        }
        
        if filename:
            params['ResponseContentDisposition'] = f'attachment; filename="{filename}"'
        
        url = self.s3.generate_presigned_url(
            'get_object',
            Params=params,
            ExpiresIn=expires_in
        )
        return url
    
    def get_public_url(self, key: str) -> str:
        """Get public URL for a file (if bucket is public)"""
        if settings.s3_endpoint_url:
            return f"{settings.s3_endpoint_url}/{self.bucket}/{key}"
        return f"https://{self.bucket}.s3.{settings.s3_region}.amazonaws.com/{key}"
    
    def upload_file(self, key: str, file_path: str, content_type: str = 'image/jpeg'):
        """Upload a file to S3"""
        self.s3.upload_file(
            file_path,
            self.bucket,
            key,
            ExtraArgs={'ContentType': content_type}
        )
    
    def download_file(self, key: str, file_path: str):
        """Download a file from S3"""
        self.s3.download_file(self.bucket, key, file_path)
    
    def delete_file(self, key: str):
        """Delete a file from S3"""
        self.s3.delete_object(Bucket=self.bucket, Key=key)
    
    def delete_tour_files(self, tour_id: str):
        """Delete all files for a tour"""
        # List all objects with tour prefix
        prefix = f"tours/{tour_id}/"
        response = self.s3.list_objects_v2(Bucket=self.bucket, Prefix=prefix)
        
        if 'Contents' in response:
            objects = [{'Key': obj['Key']} for obj in response['Contents']]
            if objects:
                self.s3.delete_objects(
                    Bucket=self.bucket,
                    Delete={'Objects': objects}
                )
    
    def file_exists(self, key: str) -> bool:
        """Check if a file exists in S3"""
        try:
            self.s3.head_object(Bucket=self.bucket, Key=key)
            return True
        except:
            return False
